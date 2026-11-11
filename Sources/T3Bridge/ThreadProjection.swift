import Foundation
import OstraCore

/// The client-side copy of one thread's projection.
///
/// The server sends a full snapshot, then events that each carry a whole
/// entity. `ThreadProjection` upserts those entities, decides which turn items
/// are visible, and reports the timeline changes that follow. The logic ports
/// `applyOrchestrationV2ProjectionEvent` from T3 Code's client runtime.
struct ThreadProjection: Sendable {
    /// A row of the visible timeline.
    private struct Row: Sendable {
        var item: JSONValue
        /// False for rows a forked thread inherits from its source thread.
        var isLocal: Bool
        /// The sort key the timeline uses.
        var ordinal: Int
    }

    let threadID: String

    private var runs: [String: JSONValue] = [:]
    private var attempts: [String: JSONValue] = [:]
    private var turnItems: [String: JSONValue] = [:]
    private var runtimeRequests: [String: JSONValue] = [:]
    private var providerTurns: [String: JSONValue] = [:]
    private var providerThreads: [String: JSONValue] = [:]
    private var checkpoints: [String: JSONValue] = [:]
    private var messageTexts: [String: String] = [:]
    private var subagents: [String: JSONValue] = [:]
    private var activeProviderThreadID: String?

    private var rows: [String: Row] = [:]
    /// What consumers have seen, so only real changes go out.
    private var published: [String: TimelineItem] = [:]
    private(set) var meta = ConversationMeta()
    /// The sequence of the newest state applied. A reconnect resumes after it.
    private(set) var sequence: Int?
    private(set) var isLoaded = false

    init(threadID: String) {
        self.threadID = threadID
    }

    /// The timeline in display order.
    var timeline: [TimelineItem] {
        published.values.sorted { left, right in
            left.ordinal != right.ordinal ? left.ordinal < right.ordinal : left.id < right.id
        }
    }

    // MARK: - Snapshot

    /// Replaces the projection with a snapshot stream item.
    mutating func load(snapshot: JSONValue) {
        let projection = snapshot["projection"] ?? .null
        runs = Self.index(projection.array("runs"))
        attempts = Self.index(projection.array("attempts"))
        turnItems = Self.index(projection.array("turnItems"))
        runtimeRequests = Self.index(projection.array("runtimeRequests"))
        providerTurns = Self.index(projection.array("providerTurns"))
        providerThreads = Self.index(projection.array("providerThreads"))
        checkpoints = Self.index(projection.array("checkpoints"))
        subagents = Self.index(projection.array("subagents"))
        messageTexts = [:]
        for message in projection.array("messages") {
            if let id = message.string("id"), let text = message.string("text") { messageTexts[id] = text }
        }
        activeProviderThreadID = projection.object("thread")?.nonEmptyString("activeProviderThreadId")
        sequence = snapshot.int("snapshotSequence")

        // The server's visible rows are the truth at snapshot time. Inherited
        // rows lead the list; they sort before every local row.
        rows = [:]
        let visible = projection.array("visibleTurnItems")
        let inheritedCount = visible.filter { $0.string("visibility") != "local" }.count
        var inheritedIndex = 0
        for row in visible {
            guard let item = row["item"], let id = row.string("sourceItemId") ?? item.string("id") else { continue }
            if row.string("visibility") == "local" {
                rows[id] = Row(item: turnItems[id] ?? item, isLocal: true, ordinal: item.int("ordinal") ?? 0)
            } else {
                rows[id] = Row(item: item, isLocal: false, ordinal: inheritedIndex - inheritedCount)
                inheritedIndex += 1
            }
        }
        isLoaded = true
        published = [:]
        for (id, row) in rows {
            if let mapped = map(row) { published[id] = mapped }
        }
        meta = computeMeta()
    }

    // MARK: - Events

    /// Applies one `event` stream item and returns the timeline changes it causes.
    mutating func apply(streamItem: JSONValue) -> [ConversationEvent] {
        if let itemSequence = streamItem.int("sequence") {
            if let sequence, itemSequence <= sequence { return [] }
            sequence = itemSequence
        }
        guard let event = streamItem.object("event"), let type = event.string("type") else { return [] }
        if let eventThread = event.string("threadId"), eventThread != threadID { return [] }
        let payload = event["payload"] ?? .null

        var changed: [ConversationEvent] = []
        switch type {
        case "run.created", "run.updated":
            upsert(payload, into: \.runs)
            changed += refilterLocalRows()
        case "run-attempt.created", "run-attempt.updated":
            upsert(payload, into: \.attempts)
            changed += refilterLocalRows()
        case "turn-item.updated":
            changed += applyTurnItem(payload)
        case "runtime-request.updated":
            upsert(payload, into: \.runtimeRequests)
            if let requestID = payload.string("id") {
                changed += republish { $0.item.string("requestId") == requestID }
            }
        case "message.updated":
            if let id = payload.string("id"), let text = payload.string("text") {
                messageTexts[id] = text
                changed += republish { $0.item.bool("textOmitted") == true && $0.item.string("messageId") == id }
            }
        case "provider-turn.updated":
            applyProviderTurn(payload)
        case "provider-thread.updated":
            upsert(payload, into: \.providerThreads)
        case "checkpoint.captured":
            upsert(payload, into: \.checkpoints)
        case "subagent.updated":
            upsert(payload, into: \.subagents)
        default:
            if type.hasPrefix("thread."), payload.string("id") == threadID {
                activeProviderThreadID = payload.nonEmptyString("activeProviderThreadId") ?? activeProviderThreadID
            }
        }

        let nextMeta = computeMeta()
        if nextMeta != meta {
            meta = nextMeta
            changed.append(.meta(nextMeta))
        }
        return changed
    }

    private mutating func applyTurnItem(_ payload: JSONValue) -> [ConversationEvent] {
        guard let id = payload.string("id") else { return [] }
        let previous = turnItems[id]
        turnItems[id] = payload

        var changed: [ConversationEvent] = []
        // Only interrupt requests change another item's visibility.
        if payload.string("type") == "run_interrupt_request" || previous?.string("type") == "run_interrupt_request" {
            changed += refilterLocalRows()
        }
        if isVisible(payload) {
            let row = Row(item: payload, isLocal: true, ordinal: payload.int("ordinal") ?? 0)
            rows[id] = row
            changed += publish(id, row)
        } else if rows.removeValue(forKey: id) != nil, published.removeValue(forKey: id) != nil {
            changed.append(.remove(id: id))
        }
        return changed
    }

    private mutating func applyProviderTurn(_ payload: JSONValue) {
        guard let id = payload.string("id") else { return }
        // An update without usage keeps the usage the turn already reported.
        var next = payload
        for key in ["turnTokenUsage", "tokenUsage"] where next[key] == nil || next[key]?.isNull == true {
            if let kept = providerTurns[id]?[key], !kept.isNull { next = next.setting(key, kept) }
        }
        providerTurns[id] = next
    }

    // MARK: - Visibility

    /// Ports `isOrchestrationV2TurnItemVisible`: hides rolled-back runs, queued
    /// input that was cancelled, and interrupt results of superseded attempts.
    private func isVisible(_ item: JSONValue) -> Bool {
        let runID = item.nonEmptyString("runId")
        let runStatus = runID.flatMap { runs[$0]?.string("status") }
        if runStatus == "rolled_back" { return false }
        if runStatus == "cancelled", item.string("type") == "user_message", item.string("inputIntent") == "queued_turn" {
            return false
        }
        if item.string("type") == "run_interrupt_result", let runID, let nodeID = item.nonEmptyString("nodeId") {
            let superseded = attempts.values.contains { attempt in
                attempt.string("runId") == runID
                    && attempt.string("rootNodeId") == nodeID
                    && attempt.string("status") == "superseded"
            }
            if superseded {
                let hasRequest = turnItems.values.contains { candidate in
                    candidate.string("type") == "run_interrupt_request" && candidate.string("runId") == runID
                }
                if !hasRequest { return false }
            }
        }
        return true
    }

    /// Drops local rows that a run or attempt change made invisible.
    private mutating func refilterLocalRows() -> [ConversationEvent] {
        var changed: [ConversationEvent] = []
        for (id, row) in rows where row.isLocal && !isVisible(row.item) {
            rows.removeValue(forKey: id)
            if published.removeValue(forKey: id) != nil { changed.append(.remove(id: id)) }
        }
        return changed
    }

    // MARK: - Publishing

    private var itemContext: T3Mapper.ItemContext {
        T3Mapper.ItemContext(
            runtimeRequest: { [runtimeRequests] in runtimeRequests[$0] },
            messageText: { [messageTexts] in messageTexts[$0] },
            checkpointFiles: { [checkpoints] in checkpoints[$0]?["files"]?.arrayValue },
            subagent: { [subagents] in subagents[$0] }
        )
    }

    private func map(_ row: Row) -> TimelineItem? {
        T3Mapper.timelineItem(row.item, ordinal: row.ordinal, context: itemContext)
    }

    private mutating func publish(_ id: String, _ row: Row) -> [ConversationEvent] {
        guard let mapped = map(row) else {
            return published.removeValue(forKey: id) != nil ? [.remove(id: id)] : []
        }
        guard published[id] != mapped else { return [] }
        published[id] = mapped
        return [.upsert(mapped)]
    }

    /// Maps the matching rows again, after an entity they refer to changed.
    private mutating func republish(where matches: (Row) -> Bool) -> [ConversationEvent] {
        var changed: [ConversationEvent] = []
        for (id, row) in rows where matches(row) {
            changed += publish(id, row)
        }
        return changed
    }

    // MARK: - Derived values

    private func computeMeta() -> ConversationMeta {
        var input = 0
        var output = 0
        var cached = 0
        var sawUsage = false
        for turn in providerTurns.values {
            guard let usage = turn.object("turnTokenUsage") ?? turn.object("tokenUsage") else { continue }
            sawUsage = true
            input += usage.int("inputTokens") ?? 0
            output += usage.int("outputTokens") ?? 0
            cached += usage.int("cachedInputTokens") ?? 0
        }

        var contextUsage: Double?
        let usageThread = activeProviderThreadID.flatMap { providerThreads[$0] }
            ?? providerThreads.values
                .filter { $0.object("contextUsage") != nil }
                .max { ($0.string("updatedAt") ?? "") < ($1.string("updatedAt") ?? "") }
        if let snapshot = usageThread?.object("contextUsage"),
            let used = snapshot.double("usedTokens"),
            let limit = snapshot.double("maxTokens"), limit > 0
        {
            contextUsage = min(max(used / limit, 0), 1)
        }

        return ConversationMeta(
            contextUsage: contextUsage,
            inputTokens: sawUsage ? input : nil,
            outputTokens: sawUsage ? output : nil,
            cachedInputTokens: sawUsage ? cached : nil,
            completedRunCount: latestCheckpointTurnCount
        )
    }

    /// The run ordinal of the newest checkpoint. The thread diff covers the
    /// runs up to it.
    var latestCheckpointTurnCount: Int {
        checkpoints.values.compactMap { $0.int("appRunOrdinal") }.max() ?? 0
    }

    /// The request that blocks the thread, with the prompt and questions from
    /// its turn item. The oldest pending request comes first.
    var pendingRequest: PendingRequest? {
        let pending = runtimeRequests.values
            .filter { $0.string("status") == "pending" }
            .min { ($0.string("createdAt") ?? "") < ($1.string("createdAt") ?? "") }
        guard let pending, let id = pending.string("id") else { return nil }
        let item = turnItems.values.first { $0.string("requestId") == id }
        let options = (item?.array("options") ?? []).compactMap { option -> PendingRequest.Option? in
            guard
                let decision = option.string("decision").flatMap(ApprovalDecision.init(rawValue:)),
                let label = option.nonEmptyString("label")
            else { return nil }
            return PendingRequest.Option(decision: decision, label: label)
        }
        return PendingRequest(
            id: RequestID(id),
            kind: T3Mapper.requestKind(pending.string("kind")),
            prompt: item?.nonEmptyString("prompt") ?? item?.nonEmptyString("reason"),
            options: options,
            questions: T3Mapper.questions(item?.array("questions") ?? [])
        )
    }

    /// The questions of a user-input request, as the server sent them.
    func wireQuestions(for requestID: String) -> [JSONValue] {
        turnItems.values.first { $0.string("requestId") == requestID }?.array("questions") ?? []
    }

    /// The run to interrupt: the newest run that hasn't finished.
    var activeRunID: String? {
        let live: Set<String> = ["preparing", "queued", "starting", "running", "waiting"]
        return runs.values
            .filter { live.contains($0.string("status") ?? "") }
            .max { ($0.int("ordinal") ?? 0) < ($1.int("ordinal") ?? 0) }?
            .string("id")
    }

    // MARK: - Helpers

    private static func index(_ entities: [JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        result.reserveCapacity(entities.count)
        for entity in entities {
            if let id = entity.string("id") { result[id] = entity }
        }
        return result
    }

    private mutating func upsert(_ entity: JSONValue, into keyPath: WritableKeyPath<ThreadProjection, [String: JSONValue]>) {
        guard let id = entity.string("id") else { return }
        self[keyPath: keyPath][id] = entity
    }
}
