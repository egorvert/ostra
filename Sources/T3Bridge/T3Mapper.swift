import Foundation
import OstraCore

/// Translates T3 wire entities into Ostra's domain models.
///
/// Every function reads leniently: a missing or unexpected field yields a
/// default or nil, never a crash.
enum T3Mapper {
    // MARK: - Projects and providers

    static func project(_ json: JSONValue) -> Project? {
        guard let id = json.string("id"), let root = json.nonEmptyString("workspaceRoot") else { return nil }
        let title = json.nonEmptyString("title") ?? URL(fileURLWithPath: root).lastPathComponent
        return Project(id: ProjectID(id), title: title, path: root)
    }

    /// True when the project record is deleted or archived, so pickers should hide it.
    static func isProjectHidden(_ json: JSONValue) -> Bool {
        json.nonEmptyString("deletedAt") != nil || json.nonEmptyString("archivedAt") != nil
    }

    static func providers(fromServerConfig config: JSONValue) -> [ProviderInfo] {
        config.array("providers").compactMap(provider)
    }

    static func provider(_ json: JSONValue) -> ProviderInfo? {
        guard let id = json.string("instanceId") else { return nil }
        let enabled = json.bool("enabled") ?? false
        let installed = json.bool("installed") ?? false
        let status = json.string("status")
        let ready = enabled && installed && status == "ready"
        let models = json.array("models").compactMap { model -> ProviderInfo.Model? in
            guard let slug = model.string("slug") else { return nil }
            return ProviderInfo.Model(
                id: slug,
                name: model.nonEmptyString("name") ?? slug,
                isDefault: model.bool("isDefault") ?? false
            )
        }
        return ProviderInfo(
            id: id,
            name: json.nonEmptyString("displayName") ?? id,
            isReady: ready,
            statusMessage: ready ? nil : json.nonEmptyString("message"),
            models: models,
            supportedRuntimeModes: json.array("supportedRuntimeModes").compactMap {
                $0.stringValue.flatMap(RuntimeMode.init(rawValue:))
            }
        )
    }

    // MARK: - Agents

    /// Maps a shell thread to an agent.
    ///
    /// - Parameters:
    ///   - thread: The `ThreadShell` entity.
    ///   - projectRoots: Workspace roots by project ID, for the working directory.
    ///   - pendingDetail: The pending request with its prompt and questions, when
    ///     the thread's detail stream has supplied them. The shell only carries
    ///     the request's ID and kind.
    ///   - archived: True when the thread came from the archive.
    static func agent(
        _ thread: JSONValue,
        projectRoots: [String: String],
        pendingDetail: PendingRequest? = nil,
        archived: Bool = false
    ) -> AgentSnapshot? {
        guard let id = thread.string("id"), let projectID = thread.string("projectId") else { return nil }

        let summary = thread.object("pendingRuntimeRequest")
        var pending: PendingRequest?
        if let summary, let requestID = summary.string("id") {
            if let pendingDetail, pendingDetail.id.rawValue == requestID {
                pending = pendingDetail
            } else {
                pending = PendingRequest(id: RequestID(requestID), kind: requestKind(summary.string("kind")))
            }
        }
        // A non-blocking request is a question the run keeps working past.
        let pendingBlocks = summary != nil && summary?.bool("blocking") != false
        let status = thread.string("status") ?? "idle"
        let phase = phase(status: status, blockingRequestKind: pendingBlocks ? pending?.kind : nil)

        let lineage = thread.object("lineage")
        let isNested = lineage?.string("relationshipToParent") == "subagent" || lineage?.bool("sideChat") == true
        let parent = isNested ? lineage?.string("parentThreadId").map(AgentID.init) : nil

        let model = thread.object("modelSelection")
        let createdAt = thread.date("createdAt") ?? .now
        return AgentSnapshot(
            id: AgentID(id),
            projectID: ProjectID(projectID),
            title: thread.nonEmptyString("title") ?? "Untitled",
            providerID: thread.string("providerInstanceId") ?? model?.string("instanceId") ?? "",
            model: model?.string("model") ?? "",
            runtimeMode: thread.string("runtimeMode").flatMap(RuntimeMode.init(rawValue:)) ?? .fullAccess,
            interactionMode: thread.string("interactionMode").flatMap(InteractionMode.init(rawValue:)) ?? .normal,
            phase: phase,
            errorMessage: phase == .failed ? thread.nonEmptyString("lastError") : nil,
            pendingRequest: pending,
            branch: thread.nonEmptyString("branch"),
            workingDirectory: thread.nonEmptyString("worktreePath") ?? projectRoots[projectID],
            activeRunID: thread.nonEmptyString("activeRunId")
                ?? (phase.isActive ? thread.nonEmptyString("latestRunId") : nil),
            parentID: parent,
            createdAt: createdAt,
            updatedAt: thread.date("updatedAt") ?? createdAt,
            completedAt: thread.date("latestRunCompletedAt"),
            lastVisitedAt: thread.date("lastVisitedAt"),
            isArchived: archived || thread.nonEmptyString("archivedAt") != nil
        )
    }

    /// Derives the phase from the shell status and the blocking request.
    ///
    /// A blocking request wins over a live status: the shell keeps reporting
    /// `running` while an approval waits. `waiting` without a request means the
    /// provider turn ended and background work or finalization continues.
    static func phase(status: String, blockingRequestKind: PendingRequest.Kind?) -> AgentPhase {
        let live = ["preparing", "queued", "starting", "running", "waiting"].contains(status)
        if live, let kind = blockingRequestKind {
            return kind == .userInput ? .awaitingInput : .awaitingApproval
        }
        switch status {
        case "preparing", "queued", "starting": return .starting
        case "running", "waiting": return .working
        case "completed": return .done
        case "failed": return .failed
        case "interrupted", "cancelled", "rolled_back": return .interrupted
        default: return .idle
        }
    }

    static func requestKind(_ wire: String?) -> PendingRequest.Kind {
        switch wire {
        case "command": .command
        case "file-change": .fileChange
        case "file-read": .fileRead
        case "permission": .permission
        case "user_input": .userInput
        default: .other
        }
    }

    // MARK: - Questions

    static func questions(_ json: [JSONValue]) -> [PendingRequest.Question] {
        json.compactMap { question in
            guard let id = question.string("id") else { return nil }
            let choices = question.array("options").compactMap { option -> PendingRequest.Question.Choice? in
                guard let label = option.nonEmptyString("label") else { return nil }
                return PendingRequest.Question.Choice(label: label, detail: option.nonEmptyString("description"))
            }
            return PendingRequest.Question(
                id: id,
                header: question.nonEmptyString("header"),
                prompt: question.nonEmptyString("question") ?? question.nonEmptyString("header") ?? "",
                choices: choices,
                allowsMultiple: question.bool("multiSelect") ?? false,
                allowsFreeText: question.bool("allowCustomAnswer") ?? true
            )
        }
    }

    /// Flattens the server's answers, which are strings or string lists, to text.
    static func answerText(_ answers: JSONValue?) -> [String: String] {
        guard case .object(let members)? = answers else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in members {
            switch value {
            case .string(let text):
                result[key] = text
            case .array(let values):
                result[key] = values.compactMap(\.stringValue).joined(separator: ", ")
            default:
                continue
            }
        }
        return result
    }

    /// Builds the wire answers for a user-input request.
    ///
    /// A choice's label maps to its wire value when the option defines one. A
    /// multi-select question takes one selection per line.
    static func wireAnswers(_ answers: [String: String], questions: [JSONValue]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        let byID = Dictionary(
            questions.compactMap { question in question.string("id").map { ($0, question) } },
            uniquingKeysWith: { first, _ in first }
        )
        for (questionID, text) in answers {
            guard let question = byID[questionID] else {
                result[questionID] = .string(text)
                continue
            }
            let options = question.array("options")
            func wireValue(_ answer: String) -> String {
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                let match = options.first { $0.string("label")?.trimmingCharacters(in: .whitespaces) == trimmed }
                return match?.string("value") ?? answer
            }
            if question.bool("multiSelect") == true {
                let selections = text.split(whereSeparator: \.isNewline)
                    .map { wireValue(String($0)) }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let allAreOptions = selections.allSatisfy { selection in
                    options.contains { ($0.string("value") ?? $0.string("label")) == selection }
                }
                // Free text on a multi-select question goes through as one custom answer.
                result[questionID] = allAreOptions && !selections.isEmpty
                    ? .array(selections.map(JSONValue.string))
                    : .string(text)
            } else {
                result[questionID] = .string(wireValue(text))
            }
        }
        return .object(result)
    }

    // MARK: - Timeline items

    static func itemStatus(_ wire: String?) -> TimelineItem.Status {
        switch wire {
        case "idle", "pending": .pending
        case "running": .running
        case "waiting": .waiting
        case "failed": .failed
        case "cancelled", "interrupted": .cancelled
        default: .completed
        }
    }

    /// Maps a turn item to a timeline row. Returns nil for item types Ostra doesn't show.
    ///
    /// - Parameters:
    ///   - item: The turn item entity.
    ///   - ordinal: Overrides the item's own ordinal, for rows inherited from a parent thread.
    ///   - context: Looks up the entities an item refers to.
    static func timelineItem(_ item: JSONValue, ordinal: Int? = nil, context: ItemContext = .empty) -> TimelineItem? {
        guard let id = item.string("id"), let content = content(of: item, context: context) else { return nil }
        return TimelineItem(
            id: id,
            ordinal: ordinal ?? item.int("ordinal") ?? 0,
            runID: item.nonEmptyString("runId"),
            status: itemStatus(item.string("status")),
            startedAt: item.date("startedAt"),
            completedAt: item.date("completedAt"),
            content: content
        )
    }

    /// The entities that turn items point at.
    struct ItemContext {
        var runtimeRequest: (String) -> JSONValue? = { _ in nil }
        var messageText: (String) -> String? = { _ in nil }
        var checkpointFiles: (String) -> [JSONValue]? = { _ in nil }
        var subagent: (String) -> JSONValue? = { _ in nil }

        static var empty: ItemContext { ItemContext() }
    }

    private static func content(of item: JSONValue, context: ItemContext) -> TimelineItem.Content? {
        switch item.string("type") {
        case "user_message":
            return .userMessage(text: messageText(of: item, context: context))
        case "assistant_message":
            return .assistantMessage(
                text: messageText(of: item, context: context),
                streaming: item.bool("streaming") ?? false
            )
        case "reasoning":
            return .reasoning(text: item.string("text") ?? "", streaming: item.bool("streaming") ?? false)
        case "proposed_plan":
            return .plan(text: item.string("markdown") ?? "")
        case "todo_list":
            let entries = item.array("steps").compactMap { step -> TodoEntry? in
                guard let text = step.nonEmptyString("text") else { return nil }
                let state: TodoEntry.State =
                    switch step.string("status") {
                    case "completed": .completed
                    case "running": .inProgress
                    default: .pending
                    }
                return TodoEntry(text: text, state: state)
            }
            return .todos(entries)
        case "user_input_request":
            guard let requestID = item.string("requestId") else { return nil }
            let request = context.runtimeRequest(requestID)
            let answers = request?["answers"] ?? item.object("questionAnswer")?["answers"]
            return .question(
                QuestionRecord(
                    requestID: RequestID(requestID),
                    questions: questions(item.array("questions")),
                    answers: answerText(answers)
                )
            )
        case "file_change":
            return .fileChange(fileChanges(of: item))
        case "command_execution":
            return .command(
                CommandCall(
                    command: item.string("input") ?? "",
                    title: item.nonEmptyString("title"),
                    output: item.string("output"),
                    exitCode: item.int("exitCode")
                )
            )
        case "file_search":
            let results = item.array("results").compactMap { result -> String? in
                guard let file = result.nonEmptyString("fileName") else { return nil }
                if let line = result.int("line") { return "\(file):\(line)" }
                return file
            }
            return .tool(
                ToolCall(
                    name: item.nonEmptyString("title") ?? "Search files",
                    summary: item.nonEmptyString("pattern"),
                    output: results.isEmpty ? nil : results.joined(separator: "\n")
                )
            )
        case "web_search":
            let patterns = item.array("patterns").compactMap(\.stringValue)
            let results = item.array("results").compactMap { result -> String? in
                let title = result.nonEmptyString("title")
                let url = result.nonEmptyString("url")
                switch (title, url) {
                case (let title?, let url?): return "\(title) — \(url)"
                case (let title?, nil): return title
                case (nil, let url?): return url
                default: return nil
                }
            }
            return .tool(
                ToolCall(
                    name: item.nonEmptyString("title") ?? "Web search",
                    summary: patterns.isEmpty ? nil : patterns.joined(separator: ", "),
                    output: results.isEmpty ? nil : results.joined(separator: "\n")
                )
            )
        case "dynamic_tool":
            return .tool(
                ToolCall(
                    name: item.nonEmptyString("toolName") ?? item.nonEmptyString("title") ?? "Tool",
                    summary: item.nonEmptyString("viewedImagePath") ?? summarize(item["input"]),
                    output: readableText(item["output"])
                )
            )
        case "approval_request":
            guard let requestID = item.string("requestId") else { return nil }
            return .approval(
                ApprovalRecord(
                    requestID: RequestID(requestID),
                    kind: requestKind(item.string("requestKind")),
                    prompt: item.nonEmptyString("prompt") ?? item.nonEmptyString("reason"),
                    decision: decision(for: context.runtimeRequest(requestID), itemStatus: item.string("status"))
                )
            )
        case "checkpoint":
            var files = item.array("files")
            if item.bool("filesOmitted") == true, let id = item.string("checkpointId"),
                let stored = context.checkpointFiles(id)
            {
                files = stored
            }
            return .checkpoint(
                files.compactMap { file -> FileStat? in
                    guard let path = file.nonEmptyString("path") else { return nil }
                    return FileStat(
                        path: path,
                        additions: file.int("additions") ?? 0,
                        deletions: file.int("deletions") ?? 0
                    )
                }
            )
        case "subagent":
            let stored = item.string("subagentId").flatMap(context.subagent)
            let prompt = item.bool("promptOmitted") == true ? stored?.string("prompt") : item.string("prompt")
            let result = item.bool("resultOmitted") == true ? stored?.string("result") : item.string("result")
            return .subagent(
                SubagentRecord(
                    name: item.nonEmptyString("title") ?? stored?.nonEmptyString("title") ?? "Subagent",
                    prompt: prompt,
                    result: result ?? item.nonEmptyString("progress")
                )
            )
        case "system_notice":
            return notice(item.string("message"), level: .info)
        case "run_interrupt_request":
            return notice(item.string("message"), level: .info)
        case "run_interrupt_result":
            return notice(item.string("message"), level: .warning)
        case "error":
            return notice(item.object("failure")?.string("message") ?? "The run failed.", level: .error)
        case "compaction":
            return notice(item.nonEmptyString("summary").map { "Compacted the context. \($0)" } ?? "Compacted the context.", level: .info)
        case "handoff":
            let target = item.nonEmptyString("toModel") ?? item.nonEmptyString("toProviderInstanceId") ?? "another provider"
            return notice("Handed the conversation off to \(target).", level: .info)
        case "notification":
            let summary = item.nonEmptyString("summary") ?? item.nonEmptyString("title")
            let text = [summary, item.nonEmptyString("detail")].compactMap { $0 }.joined(separator: "\n")
            return notice(text, level: item.string("outcome") == "failed" ? .error : .info)
        default:
            return nil
        }
    }

    private static func notice(_ text: String?, level: NoticeLevel) -> TimelineItem.Content? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .notice(text: text, level: level)
    }

    private static func messageText(of item: JSONValue, context: ItemContext) -> String {
        if item.bool("textOmitted") == true, let id = item.string("messageId"), let text = context.messageText(id) {
            return text
        }
        return item.string("text") ?? ""
    }

    private static func fileChanges(of item: JSONValue) -> [FileChange] {
        let details = item.array("changes").compactMap { change -> FileChange? in
            guard let path = change.nonEmptyString("path") else { return nil }
            return FileChange(
                path: path,
                operation: fileOperation(change.string("operation")),
                oldPath: change.nonEmptyString("oldPath")
            )
        }
        if !details.isEmpty { return details }
        guard let name = item.nonEmptyString("fileName") else { return [] }
        return [FileChange(path: name, operation: .update)]
    }

    static func fileOperation(_ wire: String?) -> FileChange.Operation {
        switch wire?.lowercased() {
        case "add", "create", "created", "added", "write": .add
        case "update", "modify", "modified", "edit", "updated": .update
        case "delete", "remove", "deleted", "removed": .delete
        case "rename", "move", "renamed", "moved": .rename
        default: .other
        }
    }

    /// The user's decision on an approval. Nil while the request waits.
    static func decision(for request: JSONValue?, itemStatus: String?) -> ApprovalDecision? {
        if let decision = request?.string("decision").flatMap(ApprovalDecision.init(rawValue:)) {
            return decision
        }
        switch request?.string("status") {
        case "pending": return nil
        case "cancelled", "expired": return .cancel
        case "resolved": return .accept
        default: break
        }
        // No request entity: fall back to the item's own state.
        switch itemStatus {
        case "completed": return .accept
        case "cancelled", "interrupted", "failed": return .cancel
        default: return nil
        }
    }

    /// A one-line summary of a tool input.
    static func summarize(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        let text: String
        switch value {
        case .string(let string):
            text = string
        case .object(let members):
            // Prefer the fields that usually carry the point of the call.
            let preferred = ["command", "query", "path", "file_path", "url", "pattern", "prompt", "description"]
            if let key = preferred.first(where: { members[$0]?.stringValue != nil }), let found = members[key]?.stringValue {
                text = found
            } else {
                text = value.serialized(sortedKeys: true)
            }
        default:
            text = value.serialized(sortedKeys: true)
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    /// Text for a tool output: a string as is, anything else as JSON.
    static func readableText(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if let text = value.stringValue { return text.isEmpty ? nil : text }
        return value.serialized(sortedKeys: true)
    }
}
