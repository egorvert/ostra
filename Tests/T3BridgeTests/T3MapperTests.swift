import Foundation
import OstraCore
import Testing
@testable import T3Bridge

@Suite struct ShellMappingTests {
    private let roots = ["1250418c-a713-4f3e-8420-5a6536dcd0d2": "/tmp/t3probe/proj"]

    private func capturedThreads() throws -> [JSONValue] {
        try capturedItems(CapturedFrames.shell)
            .filter { $0.string("kind") == "thread.updated" }
            .compactMap { $0["thread"] }
    }

    @Test func capturedThreadMapsToAnAgent() throws {
        let thread = try #require(try capturedThreads().first)
        let agent = try #require(T3Mapper.agent(thread, projectRoots: roots))
        #expect(agent.id.rawValue == "thread:project:1250418c-a713-4f3e-8420-5a6536dcd0d2:1433e791-ee72-4c07-8165-f9ca40715f30")
        #expect(agent.projectID.rawValue == "1250418c-a713-4f3e-8420-5a6536dcd0d2")
        #expect(agent.title == "Probe thread")
        #expect(agent.providerID == "codex")
        #expect(agent.model == "gpt-5.6-luna")
        #expect(agent.runtimeMode == .approvalRequired)
        #expect(agent.interactionMode == .normal)
        #expect(agent.phase == .starting)
        #expect(agent.workingDirectory == "/tmp/t3probe/proj")
        #expect(agent.activeRunID?.hasSuffix(":ordinal:1") == true)
        #expect(agent.parentID == nil)
        #expect(!agent.isArchived)
        #expect(agent.pendingRequest == nil)
        #expect(agent.createdAt == JSONValue.parseDate("2026-11-11T10:36:24.231Z"))
    }

    @Test func capturedRunWalksThroughThePhases() throws {
        let agents = try capturedThreads().compactMap { T3Mapper.agent($0, projectRoots: roots) }
        var collapsed: [AgentPhase] = []
        for agent in agents where collapsed.last != agent.phase { collapsed.append(agent.phase) }
        // The run prepares, works, stops three times for an approval, and finishes. The
        // shell reports "running" through each approval and "waiting" while it finalizes.
        #expect(
            collapsed == [
                .starting, .working,
                .awaitingApproval, .working,
                .awaitingApproval, .working,
                .awaitingApproval, .working,
                .done,
            ]
        )
        let blocked = agents.filter { $0.phase == .awaitingApproval }
        #expect(blocked.compactMap(\.pendingRequest?.kind) == [.command, .command, .fileChange])
        #expect(blocked.allSatisfy { $0.needsAttention })
        // The shell summary has no prompt; the detail stream supplies it.
        #expect(blocked.allSatisfy { $0.pendingRequest?.prompt == nil })
    }

    @Test func finishedThreadHasAnUnseenResult() throws {
        let thread = try #require(try capturedThreads().last)
        let agent = try #require(T3Mapper.agent(thread, projectRoots: roots))
        #expect(agent.phase == .done)
        #expect(agent.activeRunID == nil)
        #expect(agent.completedAt == JSONValue.parseDate("2026-11-11T10:36:45.403Z"))
        #expect(agent.lastVisitedAt == JSONValue.parseDate("2026-11-11T10:36:24.245Z"))
        #expect(agent.hasUnseenResult)
        #expect(agent.needsAttention)
    }

    @Test(arguments: [
        ("idle", nil, AgentPhase.idle),
        ("preparing", nil, .starting),
        ("queued", nil, .starting),
        ("starting", nil, .starting),
        ("running", nil, .working),
        ("waiting", nil, .working),
        ("completed", nil, .done),
        ("failed", nil, .failed),
        ("interrupted", nil, .interrupted),
        ("cancelled", nil, .interrupted),
        ("rolled_back", nil, .interrupted),
        ("some_future_status", nil, .idle),
        // A blocking request wins while the run is live: the shell keeps saying "running".
        ("running", PendingRequest.Kind.command, .awaitingApproval),
        ("waiting", .fileChange, .awaitingApproval),
        ("running", .userInput, .awaitingInput),
        ("starting", .permission, .awaitingApproval),
        // A stale request on a finished run doesn't block anything.
        ("completed", .command, .done),
        ("failed", .userInput, .failed),
    ] as [(String, PendingRequest.Kind?, AgentPhase)])
    func phaseFollowsStatusAndBlockingRequest(status: String, kind: PendingRequest.Kind?, expected: AgentPhase) {
        #expect(T3Mapper.phase(status: status, blockingRequestKind: kind) == expected)
    }

    private func thread(_ overrides: [String: JSONValue]) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": "t1", "projectId": "p1", "title": "Task", "providerInstanceId": "codex",
            "modelSelection": ["instanceId": "codex", "model": "m"],
            "runtimeMode": "auto-accept-edits", "interactionMode": "plan",
            "branch": nil, "worktreePath": nil, "status": "running",
            "lineage": ["parentThreadId": nil, "relationshipToParent": nil, "rootThreadId": "t1"],
            "latestRunId": "run-1", "activeRunId": nil, "pendingRuntimeRequest": nil,
            "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:01:00.000Z",
        ]
        for (key, value) in overrides { members[key] = value }
        return .object(members)
    }

    @Test func pendingRequestSummaryBlocksTheAgent() throws {
        let json = thread(["pendingRuntimeRequest": ["id": "rq-1", "kind": "command", "createdAt": "2026-01-01T00:00:30.000Z"]])
        let agent = try #require(T3Mapper.agent(json, projectRoots: [:]))
        #expect(agent.phase == .awaitingApproval)
        #expect(agent.pendingRequest == PendingRequest(id: RequestID("rq-1"), kind: .command))
        #expect(agent.runtimeMode == .autoAcceptEdits)
        #expect(agent.interactionMode == .plan)
        // The shell leaves activeRunId null at times; the latest run stands in while the thread is live.
        #expect(agent.activeRunID == "run-1")
    }

    @Test func detailReplacesTheSummaryOnlyForTheSameRequest() throws {
        let json = thread(["pendingRuntimeRequest": ["id": "rq-2", "kind": "user_input", "createdAt": "x"]])
        let question = PendingRequest.Question(id: "q1", prompt: "Which one?")
        let matching = PendingRequest(id: RequestID("rq-2"), kind: .userInput, questions: [question])
        let stale = PendingRequest(id: RequestID("rq-1"), kind: .command, prompt: "ls")

        let withDetail = try #require(T3Mapper.agent(json, projectRoots: [:], pendingDetail: matching))
        #expect(withDetail.phase == .awaitingInput)
        #expect(withDetail.pendingRequest?.questions == [question])

        let withStale = try #require(T3Mapper.agent(json, projectRoots: [:], pendingDetail: stale))
        #expect(withStale.pendingRequest == PendingRequest(id: RequestID("rq-2"), kind: .userInput))
    }

    @Test func nonBlockingQuestionKeepsTheAgentWorking() throws {
        let json = thread(["pendingRuntimeRequest": ["id": "rq-3", "kind": "user_input", "createdAt": "x", "blocking": false]])
        let agent = try #require(T3Mapper.agent(json, projectRoots: [:]))
        #expect(agent.phase == .working)
        #expect(agent.pendingRequest?.id == RequestID("rq-3"))
    }

    @Test func failedThreadCarriesItsError() throws {
        let agent = try #require(T3Mapper.agent(thread(["status": "failed", "lastError": "Usage limit reached"]), projectRoots: [:]))
        #expect(agent.phase == .failed)
        #expect(agent.errorMessage == "Usage limit reached")
        #expect(agent.activeRunID == nil)
    }

    @Test func worktreeWinsOverTheProjectRoot() throws {
        let agent = try #require(
            T3Mapper.agent(thread(["worktreePath": "/work/tree", "branch": "ostra/fix"]), projectRoots: ["p1": "/repo"])
        )
        #expect(agent.workingDirectory == "/work/tree")
        #expect(agent.branch == "ostra/fix")
    }

    @Test func subagentsAndSideChatsNameTheirParent() throws {
        let subagent = thread(["lineage": ["parentThreadId": "t0", "relationshipToParent": "subagent", "rootThreadId": "t0"]])
        #expect(T3Mapper.agent(subagent, projectRoots: [:])?.parentID == AgentID("t0"))
        let sideChat = thread(["lineage": ["parentThreadId": "t0", "relationshipToParent": "fork", "rootThreadId": "t0", "sideChat": true]])
        #expect(T3Mapper.agent(sideChat, projectRoots: [:])?.parentID == AgentID("t0"))
        // A fork is a thread of its own.
        let fork = thread(["lineage": ["parentThreadId": "t0", "relationshipToParent": "fork", "rootThreadId": "t0"]])
        #expect(T3Mapper.agent(fork, projectRoots: [:])?.parentID == nil)
    }

    @Test func archiveFlagComesFromTheLocationOrTheTimestamp() throws {
        #expect(T3Mapper.agent(thread([:]), projectRoots: [:], archived: true)?.isArchived == true)
        #expect(T3Mapper.agent(thread(["archivedAt": "2026-01-02T00:00:00.000Z"]), projectRoots: [:])?.isArchived == true)
    }

    @Test func threadWithoutIdentityIsDropped() {
        #expect(T3Mapper.agent(["title": "x"], projectRoots: [:]) == nil)
        #expect(T3Mapper.agent(.null, projectRoots: [:]) == nil)
    }

    @Test func projectMapsFromTheCapturedShell() throws {
        let item = try #require(try capturedItems(CapturedFrames.shell).first { $0.string("kind") == "project.updated" })
        let json = try #require(item["project"])
        let project = try #require(T3Mapper.project(json))
        #expect(project == Project(id: ProjectID("1250418c-a713-4f3e-8420-5a6536dcd0d2"), title: "probe-proj", path: "/tmp/t3probe/proj"))
        #expect(!T3Mapper.isProjectHidden(json))
        #expect(T3Mapper.isProjectHidden(["id": "p", "deletedAt": "2026-01-01T00:00:00.000Z"]))
    }

    @Test func providersMapReadinessAndModels() {
        let config: JSONValue = [
            "providers": [
                [
                    "instanceId": "codex", "driver": "codex", "displayName": "Codex",
                    "enabled": true, "installed": true, "status": "ready",
                    "models": [
                        ["slug": "gpt-6.1-sol", "name": "GPT-6.1-Sol", "isCustom": false],
                        ["slug": "gpt-5.6-luna", "name": "GPT-5.6-Luna", "isDefault": true],
                    ],
                ],
                [
                    "instanceId": "claudeAgent", "displayName": "Claude",
                    "enabled": true, "installed": true, "status": "error",
                    "message": "Claude Code is not authenticated. Run `claude auth login` and try again.",
                    "models": [["slug": "claude-opus-5-5", "name": "Claude Opus 5.5", "isDefault": true]],
                ],
                [
                    "instanceId": "grok", "displayName": "Grok", "enabled": false, "installed": false, "status": "disabled",
                    "message": "Grok is disabled in T3 Code settings.",
                    "supportedRuntimeModes": ["approval-required", "auto", "full-access", "telepathy"],
                    "models": [],
                ],
                ["displayName": "No instance ID"],
            ],
        ]
        let providers = T3Mapper.providers(fromServerConfig: config)
        #expect(providers.map(\.id) == ["codex", "claudeAgent", "grok"])

        #expect(providers[0].isReady)
        #expect(providers[0].statusMessage == nil)
        #expect(providers[0].defaultModel?.id == "gpt-5.6-luna")
        #expect(providers[0].supports(.autoAcceptEdits))

        #expect(!providers[1].isReady)
        #expect(providers[1].statusMessage?.contains("claude auth login") == true)

        #expect(!providers[2].isReady)
        // Unknown modes drop out; the known ones restrict the provider.
        #expect(providers[2].supportedRuntimeModes == [.approvalRequired, .auto, .fullAccess])
        #expect(!providers[2].supports(.autoAcceptEdits))
    }
}

@Suite struct TimelineMappingTests {
    private func item(_ type: String, _ fields: [String: JSONValue] = [:], status: String = "completed") -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string("item-\(type)"), "threadId": "t1", "runId": "run-1", "nodeId": "n1",
            "ordinal": 1_000_042, "status": .string(status), "title": nil,
            "startedAt": "2026-11-11T10:36:34.070Z", "completedAt": "2026-11-11T10:36:35.291Z",
            "type": .string(type),
        ]
        for (key, value) in fields { members[key] = value }
        return .object(members)
    }

    private func content(_ json: JSONValue, context: T3Mapper.ItemContext = .empty) -> TimelineItem.Content? {
        T3Mapper.timelineItem(json, context: context)?.content
    }

    @Test func baseFieldsCarryOver() throws {
        let mapped = try #require(T3Mapper.timelineItem(item("reasoning", ["text": "thinking", "streaming": true], status: "running")))
        #expect(mapped.id == "item-reasoning")
        #expect(mapped.ordinal == 1_000_042)
        #expect(mapped.runID == "run-1")
        #expect(mapped.status == .running)
        #expect(mapped.startedAt == JSONValue.parseDate("2026-11-11T10:36:34.070Z"))
        #expect(mapped.completedAt == JSONValue.parseDate("2026-11-11T10:36:35.291Z"))
        #expect(mapped.content == .reasoning(text: "thinking", streaming: true))
        // An inherited row takes the ordinal the projection assigns.
        #expect(T3Mapper.timelineItem(item("reasoning", ["text": "x"]), ordinal: -3)?.ordinal == -3)
    }

    @Test(arguments: [
        ("idle", TimelineItem.Status.pending), ("pending", .pending), ("running", .running), ("waiting", .waiting),
        ("completed", .completed), ("failed", .failed), ("cancelled", .cancelled), ("interrupted", .cancelled),
    ] as [(String, TimelineItem.Status)])
    func statusMaps(wire: String, expected: TimelineItem.Status) {
        #expect(T3Mapper.itemStatus(wire) == expected)
    }

    @Test func messages() {
        #expect(content(item("user_message", ["text": "hi", "messageId": "m1", "attachments": []])) == .userMessage(text: "hi"))
        #expect(
            content(item("assistant_message", ["text": "partial", "messageId": "m2", "streaming": true]))
                == .assistantMessage(text: "partial", streaming: true)
        )
        // A deduplicated body reads from the message it names.
        let context = T3Mapper.ItemContext(messageText: { $0 == "m3" ? "restored" : nil })
        #expect(
            content(item("assistant_message", ["text": "", "textOmitted": true, "messageId": "m3", "streaming": false]), context: context)
                == .assistantMessage(text: "restored", streaming: false)
        )
    }

    @Test func commandExecution() {
        let json = item("command_execution", ["input": "npm test", "output": "ok", "exitCode": 0, "title": "Tests"])
        #expect(content(json) == .command(CommandCall(command: "npm test", title: "Tests", output: "ok", exitCode: 0)))
        let withheld = item("command_execution", ["input": "ls", "outputOmitted": true], status: "running")
        #expect(content(withheld) == .command(CommandCall(command: "ls")))
    }

    @Test func fileChange() {
        let json = item("file_change", [
            "fileName": "/repo/a.swift",
            "changes": [
                ["operation": "update", "path": "/repo/a.swift"],
                ["operation": "add", "path": "/repo/b.swift"],
                ["operation": "delete", "path": "/repo/c.swift"],
                ["operation": "rename", "path": "/repo/e.swift", "oldPath": "/repo/d.swift"],
                ["operation": "chmod", "path": "/repo/f.sh"],
            ],
        ])
        #expect(
            content(json) == .fileChange([
                FileChange(path: "/repo/a.swift", operation: .update),
                FileChange(path: "/repo/b.swift", operation: .add),
                FileChange(path: "/repo/c.swift", operation: .delete),
                FileChange(path: "/repo/e.swift", operation: .rename, oldPath: "/repo/d.swift"),
                FileChange(path: "/repo/f.sh", operation: .other),
            ])
        )
        // Without details, the file name alone still shows.
        #expect(content(item("file_change", ["fileName": "/repo/a.swift"])) == .fileChange([FileChange(path: "/repo/a.swift", operation: .update)]))
    }

    @Test func tools() {
        #expect(
            content(item("file_search", ["pattern": "TODO", "results": [["fileName": "a.swift", "line": 3], ["fileName": "b.swift"]]]))
                == .tool(ToolCall(name: "Search files", summary: "TODO", output: "a.swift:3\nb.swift"))
        )
        #expect(
            content(item("web_search", ["patterns": ["swift mutex", "swift 6"], "results": [["title": "Docs", "url": "https://example.com"]]]))
                == .tool(ToolCall(name: "Web search", summary: "swift mutex, swift 6", output: "Docs — https://example.com"))
        )
        #expect(
            content(item("dynamic_tool", ["toolName": "mcp__docs__search", "input": ["query": "glass", "limit": 3], "output": "found"]))
                == .tool(ToolCall(name: "mcp__docs__search", summary: "glass", output: "found"))
        )
        #expect(content(item("dynamic_tool", ["toolName": nil, "input": nil])) == .tool(ToolCall(name: "Tool")))
    }

    @Test func approvalTakesItsDecisionFromTheRuntimeRequest() {
        let json = item("approval_request", ["requestId": "rq-1", "requestKind": "command", "prompt": "rm -rf build"], status: "waiting")
        func record(_ request: JSONValue?) -> ApprovalRecord? {
            let context = T3Mapper.ItemContext(runtimeRequest: { _ in request })
            if case .approval(let record) = content(json, context: context) { return record }
            return nil
        }
        #expect(record(["id": "rq-1", "status": "pending"]) == ApprovalRecord(requestID: RequestID("rq-1"), kind: .command, prompt: "rm -rf build"))
        #expect(record(["id": "rq-1", "status": "resolved", "decision": "acceptForSession"])?.decision == .acceptForSession)
        #expect(record(["id": "rq-1", "status": "resolved", "decision": "decline"])?.decision == .decline)
        #expect(record(["id": "rq-1", "status": "expired"])?.decision == .cancel)
        // Without the request entity, a waiting item is pending.
        #expect(record(nil)?.decision == nil)
    }

    @Test func approvalFallsBackToTheReason() {
        let json = item("approval_request", ["requestId": "rq-9", "requestKind": "file-change", "reason": "Edit outside the workspace"])
        guard case .approval(let record) = content(json) else {
            Issue.record("not an approval")
            return
        }
        #expect(record.kind == .fileChange)
        #expect(record.prompt == "Edit outside the workspace")
        #expect(record.decision == .accept)
    }

    @Test func questionCarriesChoicesAndAnswers() {
        let json = item("user_input_request", [
            "requestId": "rq-2",
            "questions": [
                [
                    "id": "q1", "header": "Stack", "question": "Which language?",
                    "options": [["label": "Swift", "description": "Native"], ["label": "Rust", "description": "Portable"]],
                    "multiSelect": false, "allowCustomAnswer": false,
                ],
                ["id": "q2", "header": "Targets", "question": "Which platforms?", "options": [], "multiSelect": true],
            ],
        ], status: "waiting")
        let context = T3Mapper.ItemContext(runtimeRequest: { _ in ["id": "rq-2", "answers": ["q1": "Swift", "q2": ["macOS", "iOS"]]] })
        guard case .question(let record) = content(json, context: context) else {
            Issue.record("not a question")
            return
        }
        #expect(record.requestID == RequestID("rq-2"))
        #expect(record.questions.map(\.id) == ["q1", "q2"])
        #expect(record.questions[0].header == "Stack")
        #expect(record.questions[0].prompt == "Which language?")
        #expect(record.questions[0].choices == [.init(label: "Swift", detail: "Native"), .init(label: "Rust", detail: "Portable")])
        #expect(!record.questions[0].allowsFreeText)
        #expect(record.questions[1].allowsMultiple)
        #expect(record.questions[1].allowsFreeText)
        #expect(record.answers == ["q1": "Swift", "q2": "macOS, iOS"])
    }

    @Test func planTodosCheckpointAndSubagent() {
        #expect(content(item("proposed_plan", ["planId": "p1", "markdown": "# Plan", "streaming": false])) == .plan(text: "# Plan"))
        #expect(
            content(item("todo_list", ["planId": "p1", "steps": [
                ["id": "1", "text": "Read", "status": "completed"],
                ["id": "2", "text": "Write", "status": "running"],
                ["id": "3", "text": "Test", "status": "pending"],
            ]]))
                == .todos([
                    TodoEntry(text: "Read", state: .completed),
                    TodoEntry(text: "Write", state: .inProgress),
                    TodoEntry(text: "Test", state: .pending),
                ])
        )
        #expect(
            content(item("checkpoint", ["checkpointId": "c1", "files": [["path": "a.swift", "kind": "modified", "additions": 4, "deletions": 1]]]))
                == .checkpoint([FileStat(path: "a.swift", additions: 4, deletions: 1)])
        )
        #expect(
            content(item("subagent", ["subagentId": "s1", "prompt": "Review the diff", "result": "Looks fine", "title": "Reviewer"]))
                == .subagent(SubagentRecord(name: "Reviewer", prompt: "Review the diff", result: "Looks fine"))
        )
    }

    @Test func noticesKeepTheirLevel() {
        #expect(content(item("system_notice", ["message": "Switched model"])) == .notice(text: "Switched model", level: .info))
        #expect(content(item("run_interrupt_result", ["message": "Stopped by you"])) == .notice(text: "Stopped by you", level: .warning))
        // A stop request shows only while the stop is in flight.
        #expect(content(item("run_interrupt_request", ["message": "Stopped by you"], status: "running")) == .notice(text: "Stopping…", level: .info))
        #expect(content(item("run_interrupt_request", ["message": "Stopped by you"])) == nil)
        #expect(
            content(item("error", ["failure": ["class": "usage_limit", "message": "Usage limit reached", "code": nil, "retryable": false]]))
                == .notice(text: "Usage limit reached", level: .error)
        )
        #expect(content(item("compaction", ["driver": "codex"])) == .notice(text: "Compacted the context.", level: .info))
        #expect(
            content(item("handoff", ["toModel": "claude-opus-5-5", "toProviderInstanceId": "claudeAgent"]))
                == .notice(text: "Handed the conversation off to claude-opus-5-5.", level: .info)
        )
        #expect(
            content(item("notification", ["summary": "Build failed", "detail": "exit 1", "outcome": "failed"]))
                == .notice(text: "Build failed\nexit 1", level: .error)
        )
        // A notice without text is noise.
        #expect(content(item("system_notice", ["message": "  "])) == nil)
    }

    @Test func unknownAndInternalTypesAreSkipped() {
        #expect(T3Mapper.timelineItem(item("thread_created", ["targetThreadId": "t2"])) == nil)
        #expect(T3Mapper.timelineItem(item("fork")) == nil)
        #expect(T3Mapper.timelineItem(item("something_new", ["payload": 1])) == nil)
        #expect(T3Mapper.timelineItem(["type": "assistant_message", "text": "no id"]) == nil)
    }

    @Test func toolInputSummaryIsOneShortLine() {
        #expect(T3Mapper.summarize(["command": "swift build\nswift test"]) == "swift build")
        #expect(T3Mapper.summarize("plain") == "plain")
        #expect(T3Mapper.summarize(["b": 2, "a": 1]) == #"{"a":1,"b":2}"#)
        #expect(T3Mapper.summarize(.null) == nil)
        let long = String(repeating: "x", count: 400)
        #expect(T3Mapper.summarize(.string(long))?.count == 161)
    }
}

@Suite struct AnswerMappingTests {
    private let questions: [JSONValue] = [
        [
            "id": "q1", "header": "Stack", "question": "Which language?",
            "options": [["label": "Swift", "description": "Native", "value": "swift-lang"], ["label": "Rust", "description": "Portable"]],
        ],
        [
            "id": "q2", "header": "Targets", "question": "Which platforms?", "multiSelect": true,
            "options": [["label": "macOS", "description": "Desktop"], ["label": "iOS", "description": "Phone", "value": "ios"]],
        ],
    ]

    @Test func labelsMapToWireValues() {
        let wire = T3Mapper.wireAnswers(["q1": "Swift"], questions: questions)
        #expect(wire == ["q1": "swift-lang"])
        // An option without a value answers with its label; free text passes through.
        #expect(T3Mapper.wireAnswers(["q1": "Rust"], questions: questions) == ["q1": "Rust"])
        #expect(T3Mapper.wireAnswers(["q1": "Zig, actually"], questions: questions) == ["q1": "Zig, actually"])
    }

    @Test func multiSelectTakesOneSelectionPerLine() {
        #expect(T3Mapper.wireAnswers(["q2": "macOS\niOS"], questions: questions) == ["q2": ["macOS", "ios"]])
        #expect(T3Mapper.wireAnswers(["q2": "iOS"], questions: questions) == ["q2": ["ios"]])
        // Free text on a multi-select question is one custom answer.
        #expect(T3Mapper.wireAnswers(["q2": "Both, plus visionOS"], questions: questions) == ["q2": "Both, plus visionOS"])
    }

    @Test func unknownQuestionPassesThrough() {
        #expect(T3Mapper.wireAnswers(["q9": "anything"], questions: questions) == ["q9": "anything"])
    }

    @Test func serverAnswersFlattenToText() {
        #expect(T3Mapper.answerText(["a": "one", "b": ["x", "y"], "c": 3]) == ["a": "one", "b": "x, y"])
        #expect(T3Mapper.answerText(nil).isEmpty)
    }
}
