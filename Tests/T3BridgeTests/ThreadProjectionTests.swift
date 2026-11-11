import Foundation
import OstraCore
import Testing
@testable import T3Bridge

/// Splits a captured stream into its items.
func capturedItems(_ fixture: String) throws -> [JSONValue] {
    try fixture.split(whereSeparator: \.isNewline).map { try JSONValue.parse(String($0)) }
}

/// A short tag per timeline row, for asserting order and content.
private func tag(_ item: TimelineItem) -> String {
    switch item.content {
    case .userMessage: "user"
    case .assistantMessage: "assistant"
    case .reasoning: "reasoning"
    case .command: "command"
    case .fileChange: "fileChange"
    case .tool: "tool"
    case .approval(let record): "approval:\(record.decision?.rawValue ?? "pending")"
    case .question: "question"
    case .plan: "plan"
    case .todos: "todos"
    case .checkpoint: "checkpoint"
    case .subagent: "subagent"
    case .notice: "notice"
    }
}

@Suite struct ThreadProjectionTests {
    private let threadID = "thread:project:1250418c-a713-4f3e-8420-5a6536dcd0d2:1433e791-ee72-4c07-8165-f9ca40715f30"

    /// Replays the captured run and mirrors what a consumer would hold.
    private func replay() throws -> (projection: ThreadProjection, consumer: [String: TimelineItem]) {
        let items = try capturedItems(CapturedFrames.thread)
        var projection = ThreadProjection(threadID: threadID)
        var consumer: [String: TimelineItem] = [:]
        for item in items {
            if item.string("kind") == "snapshot" {
                projection.load(snapshot: item)
                consumer = Dictionary(projection.timeline.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                continue
            }
            for change in projection.apply(streamItem: item) {
                switch change {
                case .upsert(let row): consumer[row.id] = row
                case .remove(let id): consumer[id] = nil
                case .reset, .meta: break
                }
            }
        }
        return (projection, consumer)
    }

    @Test func snapshotStartsWithTheUserMessage() throws {
        let items = try capturedItems(CapturedFrames.thread)
        var projection = ThreadProjection(threadID: threadID)
        #expect(!projection.isLoaded)
        projection.load(snapshot: try #require(items.first))
        #expect(projection.isLoaded)
        #expect(projection.timeline.map(tag) == ["user", "command"])
        guard case .userMessage(let text) = try #require(projection.timeline.first).content else {
            Issue.record("the first row isn't the user message")
            return
        }
        #expect(text.hasPrefix("Run the shell command"))
    }

    @Test func replayingTheRunBuildsTheTimelineInOrder() throws {
        let (projection, consumer) = try replay()
        let expected = [
            "user", "command", "assistant",
            "command", "approval:accept",
            "reasoning",
            "command", "approval:accept",
            "approval:accept", "fileChange",
            "assistant", "checkpoint",
        ]
        #expect(projection.timeline.map(tag) == expected)
        // The incremental events leave a consumer with the same rows the projection holds.
        #expect(Set(consumer.keys) == Set(projection.timeline.map(\.id)))
        #expect(consumer.values.allSatisfy { row in projection.timeline.contains(row) })
        #expect(projection.timeline.allSatisfy { $0.status == .completed })
        #expect(projection.pendingRequest == nil)
        #expect(projection.activeRunID == nil)
    }

    @Test func rowsCarryTheirDetails() throws {
        let (projection, _) = try replay()
        let timeline = projection.timeline

        let commands = timeline.compactMap { item -> CommandCall? in
            if case .command(let call) = item.content { call } else { nil }
        }
        #expect(commands.first?.title == "Workspace ready")
        #expect(commands.contains { $0.command == "/bin/zsh -lc 'ls -la'" && $0.exitCode == 0 })
        // The stream withholds command output; the UI fetches it on demand.
        #expect(commands.allSatisfy { $0.output == nil })

        let approvals = timeline.compactMap { item -> ApprovalRecord? in
            if case .approval(let record) = item.content { record } else { nil }
        }
        #expect(approvals.map(\.kind) == [.command, .command, .fileChange])
        #expect(approvals.first?.prompt == "/bin/zsh -lc 'ls -la'")

        let changes = timeline.compactMap { item -> [FileChange]? in
            if case .fileChange(let list) = item.content { list } else { nil }
        }
        #expect(changes == [[FileChange(path: "/tmp/t3probe/proj/README.md", operation: .update)]])

        let checkpoints = timeline.compactMap { item -> [FileStat]? in
            if case .checkpoint(let files) = item.content { files } else { nil }
        }
        #expect(checkpoints == [[FileStat(path: "README.md", additions: 1, deletions: 0)]])
    }

    @Test func metaSumsUsageAndTracksTheCheckpoint() throws {
        let (projection, _) = try replay()
        #expect(projection.meta.inputTokens == 72_395)
        #expect(projection.meta.outputTokens == 472)
        #expect(projection.meta.cachedInputTokens == 53_504)
        #expect(projection.meta.completedRunCount == 1)
        #expect(projection.latestCheckpointTurnCount == 1)
        // Codex reported no context window for this thread.
        #expect(projection.meta.contextUsage == nil)
    }

    @Test func pendingRequestCarriesThePromptWhileItWaits() throws {
        let items = try capturedItems(CapturedFrames.thread)
        var projection = ThreadProjection(threadID: threadID)
        var seen: [PendingRequest] = []
        var approvalStates: [String: [String]] = [:]
        for item in items {
            if item.string("kind") == "snapshot" {
                projection.load(snapshot: item)
                continue
            }
            for change in projection.apply(streamItem: item) {
                if case .upsert(let row) = change, case .approval = row.content {
                    approvalStates[row.id, default: []].append(tag(row))
                }
            }
            if let pending = projection.pendingRequest, seen.last?.id != pending.id { seen.append(pending) }
        }
        #expect(seen.map(\.kind) == [.command, .command, .fileChange])
        #expect(seen.first?.prompt == "/bin/zsh -lc 'ls -la'")
        #expect(seen.allSatisfy { $0.prompt != nil })
        // Each approval row first appears pending and then flips to the decision.
        #expect(approvalStates.count == 3)
        #expect(approvalStates.values.allSatisfy { $0.first == "approval:pending" && $0.last == "approval:accept" })
    }

    @Test func activeRunIsKnownWhileTheRunIsLive() throws {
        let items = try capturedItems(CapturedFrames.thread)
        var projection = ThreadProjection(threadID: threadID)
        projection.load(snapshot: try #require(items.first))
        #expect(projection.activeRunID?.hasSuffix(":ordinal:1") == true)
    }

    @Test func replayedEventsAreIgnored() throws {
        let items = try capturedItems(CapturedFrames.thread)
        var projection = ThreadProjection(threadID: threadID)
        projection.load(snapshot: try #require(items.first))
        let event = try #require(items.first { $0.string("kind") == "event" && $0.object("event")?.string("type") == "turn-item.updated" })
        #expect(!projection.apply(streamItem: event).isEmpty)
        // A reconnect can replay events the projection already applied.
        #expect(projection.apply(streamItem: event).isEmpty)
    }

    @Test func eventsOfOtherThreadsAreIgnored() throws {
        let items = try capturedItems(CapturedFrames.thread)
        var projection = ThreadProjection(threadID: "thread:other")
        projection.load(snapshot: ["kind": "snapshot", "snapshotSequence": 0, "projection": [:]])
        let event = try #require(items.first { $0.string("kind") == "event" })
        #expect(projection.apply(streamItem: event).isEmpty)
        #expect(projection.timeline.isEmpty)
    }
}

/// The visibility rule ported from `isOrchestrationV2TurnItemVisible`.
@Suite struct ThreadVisibilityTests {
    private let threadID = "t1"

    private func event(_ sequence: Int, _ type: String, _ payload: JSONValue) -> JSONValue {
        [
            "kind": "event",
            "sequence": .number(Double(sequence)),
            "event": ["type": .string(type), "threadId": .string(threadID), "payload": payload],
        ]
    }

    private func item(_ id: String, type: String, run: String, ordinal: Int, extra: [String: JSONValue] = [:]) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(id), "threadId": .string(threadID), "runId": .string(run), "nodeId": "node-1",
            "ordinal": .number(Double(ordinal)), "status": "completed", "type": .string(type),
            "text": "hello", "message": "Stopped", "streaming": false, "inputIntent": "turn_start",
        ]
        for (key, value) in extra { members[key] = value }
        return .object(members)
    }

    private func loaded() -> ThreadProjection {
        var projection = ThreadProjection(threadID: threadID)
        projection.load(snapshot: ["kind": "snapshot", "snapshotSequence": 0, "projection": ["thread": ["id": "t1"]]])
        return projection
    }

    @Test func rollingBackARunRemovesItsRows() {
        var projection = loaded()
        _ = projection.apply(streamItem: event(1, "run.created", ["id": "run-1", "status": "running", "ordinal": 1]))
        _ = projection.apply(streamItem: event(2, "turn-item.updated", item("a", type: "user_message", run: "run-1", ordinal: 1)))
        _ = projection.apply(streamItem: event(3, "turn-item.updated", item("b", type: "assistant_message", run: "run-1", ordinal: 2)))
        #expect(projection.timeline.map(\.id) == ["a", "b"])

        let changes = projection.apply(streamItem: event(4, "run.updated", ["id": "run-1", "status": "rolled_back", "ordinal": 1]))
        let removed = changes.compactMap { change -> String? in
            if case .remove(let id) = change { id } else { nil }
        }
        #expect(Set(removed) == ["a", "b"])
        #expect(projection.timeline.isEmpty)

        // A late update to a rolled-back row stays hidden.
        let late = projection.apply(streamItem: event(5, "turn-item.updated", item("b", type: "assistant_message", run: "run-1", ordinal: 2)))
        #expect(late.isEmpty)
    }

    @Test func cancelledQueuedInputIsHidden() {
        var projection = loaded()
        _ = projection.apply(streamItem: event(1, "run.created", ["id": "run-2", "status": "queued", "ordinal": 2]))
        _ = projection.apply(
            streamItem: event(2, "turn-item.updated", item("q", type: "user_message", run: "run-2", ordinal: 5, extra: ["inputIntent": "queued_turn"]))
        )
        #expect(projection.timeline.map(\.id) == ["q"])
        _ = projection.apply(streamItem: event(3, "run.updated", ["id": "run-2", "status": "cancelled", "ordinal": 2]))
        #expect(projection.timeline.isEmpty)
    }

    @Test func cancelledRunKeepsItsOtherRows() {
        var projection = loaded()
        _ = projection.apply(streamItem: event(1, "run.created", ["id": "run-3", "status": "running", "ordinal": 3]))
        _ = projection.apply(streamItem: event(2, "turn-item.updated", item("u", type: "user_message", run: "run-3", ordinal: 1)))
        _ = projection.apply(streamItem: event(3, "run.updated", ["id": "run-3", "status": "cancelled", "ordinal": 3]))
        #expect(projection.timeline.map(\.id) == ["u"])
    }

    @Test func supersededInterruptResultNeedsAMatchingRequest() {
        var projection = loaded()
        _ = projection.apply(streamItem: event(1, "run.created", ["id": "run-4", "status": "running", "ordinal": 4]))
        _ = projection.apply(
            streamItem: event(2, "run-attempt.created", ["id": "attempt-1", "runId": "run-4", "rootNodeId": "node-1", "status": "superseded"])
        )
        // A plain steer leaves an interrupt result without a request: hidden.
        _ = projection.apply(streamItem: event(3, "turn-item.updated", item("r", type: "run_interrupt_result", run: "run-4", ordinal: 9)))
        #expect(projection.timeline.isEmpty)

        // A stop-then-steer pairs the result with a request: the result shows.
        let request = item("req", type: "run_interrupt_request", run: "run-4", ordinal: 8, extra: ["status": "running"])
        let changes = projection.apply(streamItem: event(4, "turn-item.updated", request))
        #expect(changes.contains { change in
            if case .upsert(let row) = change { row.id == "req" } else { false }
        })
        _ = projection.apply(streamItem: event(5, "turn-item.updated", item("r", type: "run_interrupt_result", run: "run-4", ordinal: 9)))
        #expect(projection.timeline.map(\.id) == ["req", "r"])

        // Once the stop lands, the request row gives way to the result.
        let settled = item("req", type: "run_interrupt_request", run: "run-4", ordinal: 8)
        let removal = projection.apply(streamItem: event(6, "turn-item.updated", settled))
        #expect(removal.contains { change in
            if case .remove(let id) = change { id == "req" } else { false }
        })
        #expect(projection.timeline.map(\.id) == ["r"])
    }

    @Test func unchangedItemsProduceNoEvents() {
        var projection = loaded()
        let row = item("a", type: "assistant_message", run: "run-1", ordinal: 1)
        #expect(projection.apply(streamItem: event(1, "turn-item.updated", row)).count == 1)
        // The same content under a newer sequence maps to the same row.
        #expect(projection.apply(streamItem: event(2, "turn-item.updated", row)).isEmpty)
    }

    @Test func unknownItemAndEventTypesAreSkipped() {
        var projection = loaded()
        #expect(projection.apply(streamItem: event(1, "turn-item.updated", item("x", type: "hologram", run: "run-1", ordinal: 1))).isEmpty)
        #expect(projection.apply(streamItem: event(2, "future.event", ["id": "whatever"])).isEmpty)
        #expect(projection.timeline.isEmpty)
    }

    @Test func inheritedRowsSortBeforeLocalRows() {
        var projection = ThreadProjection(threadID: threadID)
        let inherited = item("parent-item", type: "user_message", run: "run-p", ordinal: 5_000_000)
        let local = item("local-item", type: "assistant_message", run: "run-1", ordinal: 1_000_001)
        projection.load(snapshot: [
            "kind": "snapshot",
            "snapshotSequence": 7,
            "projection": [
                "thread": ["id": "t1"],
                "turnItems": [local],
                "visibleTurnItems": [
                    ["position": 0, "visibility": "inherited", "sourceThreadId": "parent", "sourceItemId": "parent-item", "item": inherited],
                    ["position": 1, "visibility": "local", "sourceThreadId": "t1", "sourceItemId": "local-item", "item": local],
                ],
            ],
        ])
        #expect(projection.timeline.map(\.id) == ["parent-item", "local-item"])
        #expect(projection.sequence == 7)
    }

    @Test func contextUsageComesFromTheActiveProviderThread() {
        var projection = ThreadProjection(threadID: threadID)
        projection.load(snapshot: [
            "kind": "snapshot",
            "snapshotSequence": 0,
            "projection": [
                "thread": ["id": "t1", "activeProviderThreadId": "pt-1"],
                "providerThreads": [["id": "pt-1", "contextUsage": ["usedTokens": 50_000, "maxTokens": 200_000]]],
            ],
        ])
        #expect(projection.meta.contextUsage == 0.25)
        let changes = projection.apply(
            streamItem: event(1, "provider-thread.updated", ["id": "pt-1", "contextUsage": ["usedTokens": 150_000, "maxTokens": 200_000]])
        )
        #expect(changes.contains { change in
            if case .meta(let meta) = change { meta.contextUsage == 0.75 } else { false }
        })
    }

    @Test func providerTurnKeepsUsageWhenAnUpdateOmitsIt() {
        var projection = loaded()
        _ = projection.apply(
            streamItem: event(1, "provider-turn.updated", ["id": "turn-1", "turnTokenUsage": ["inputTokens": 10, "outputTokens": 2]])
        )
        _ = projection.apply(streamItem: event(2, "provider-turn.updated", ["id": "turn-1", "status": "completed"]))
        #expect(projection.meta.inputTokens == 10)
        #expect(projection.meta.outputTokens == 2)
    }
}
