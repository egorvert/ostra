import Foundation
import OstraCore
import Testing
@testable import T3Bridge

/// Collects what a backend publishes so a test can wait for a state.
private actor Recorder {
    var connection: ConnectionState = .idle
    var connectionHistory: [ConnectionState] = []
    var providers: [ProviderInfo] = []
    var projects: [ProjectID: Project] = [:]
    var agents: [AgentID: AgentSnapshot] = [:]
    var removedAgents: Set<AgentID> = []
    var timeline: [String: TimelineItem] = [:]
    var meta = ConversationMeta()
    var resets = 0

    func apply(_ event: BackendEvent) {
        switch event {
        case .connection(let state):
            connection = state
            connectionHistory.append(state)
        case .providers(let list):
            providers = list
        case .snapshot(let projectList, let agentList):
            projects = Dictionary(projectList.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            agents = Dictionary(agentList.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        case .projectUpserted(let project):
            projects[project.id] = project
        case .projectRemoved(let id):
            projects[id] = nil
        case .agentUpserted(let agent):
            agents[agent.id] = agent
        case .agentRemoved(let id):
            agents[id] = nil
            removedAgents.insert(id)
        }
    }

    func apply(_ event: ConversationEvent) {
        switch event {
        case .reset(let items, let newMeta):
            timeline = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            meta = newMeta
            resets += 1
        case .upsert(let item):
            timeline[item.id] = item
        case .remove(let id):
            timeline[id] = nil
        case .meta(let newMeta):
            meta = newMeta
        }
    }

    var sortedTimeline: [TimelineItem] {
        timeline.values.sorted { $0.ordinal != $1.ordinal ? $0.ordinal < $1.ordinal : $0.id < $1.id }
    }
}

private struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Waits until `condition` holds. Live tests observe a real server, so they poll.
private func waitUntil(
    _ what: String,
    timeout: Duration,
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw WaitTimeout(description: "Timed out waiting for \(what).")
}

private func describe(_ item: TimelineItem) -> String {
    let body: String
    switch item.content {
    case .userMessage(let text): body = "user: \(text.prefix(60))"
    case .assistantMessage(let text, let streaming): body = "assistant\(streaming ? "…" : ""): \(text.prefix(60))"
    case .reasoning(let text, _): body = "reasoning: \(text.prefix(40))"
    case .command(let call): body = "command: \(call.command.prefix(60)) exit=\(call.exitCode.map(String.init) ?? "-")"
    case .fileChange(let changes): body = "fileChange: \(changes.map(\.path).joined(separator: ","))"
    case .tool(let call): body = "tool: \(call.name)"
    case .approval(let record): body = "approval(\(record.kind)): \(record.decision.map(\.rawValue) ?? "pending") \(record.prompt?.prefix(50) ?? "")"
    case .question: body = "question"
    case .plan: body = "plan"
    case .todos: body = "todos"
    case .checkpoint(let files): body = "checkpoint: \(files.map { "\($0.path)+\($0.additions)-\($0.deletions)" })"
    case .subagent: body = "subagent"
    case .notice(let text, let level): body = "notice(\(level)): \(text.prefix(60))"
    }
    return "[\(item.ordinal)] \(item.status) \(body)"
}

/// Drives a real T3 server. Set `OSTRA_T3_LIVE=1` and `OSTRA_T3_BINARY` to run it.
/// The agent runs cost a few cents of the Codex subscription.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OSTRA_T3_LIVE"] == "1"))
struct LiveIntegrationTests {
    private static func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ostra-live-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func git(_ arguments: [String], in directory: URL) async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "user.name=Ostra Test", "-c", "user.email=test@example.com"] + arguments,
            currentDirectory: directory,
            timeout: .seconds(30)
        )
        try result.requireSuccess("git \(arguments.joined(separator: " "))")
    }

    @Test(.timeLimit(.minutes(6)))
    func runsAnAgentEndToEnd() async throws {
        let support = try Self.makeTemporaryDirectory("support")
        let repository = try Self.makeTemporaryDirectory("repo")
        try Data("# Live test\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try await Self.git(["init", "-q"], in: repository)
        try await Self.git(["add", "-A"], in: repository)
        try await Self.git(["commit", "-qm", "init"], in: repository)

        let backend = T3Backend(configuration: T3Configuration(supportDirectory: support))
        let recorder = Recorder()
        let eventTask = Task {
            for await event in backend.events() { await recorder.apply(event) }
        }
        defer { eventTask.cancel() }

        await backend.start()
        do {
            try await waitUntil("the engine to become ready", timeout: .seconds(120)) {
                await recorder.connection == .ready
            }
            // The first provider list arrives before the server finishes probing each CLI.
            do {
                try await waitUntil("Codex to become ready", timeout: .seconds(60)) {
                    await recorder.providers.first { $0.id == "codex" }?.isReady == true
                }
            } catch {
                let codex = await recorder.providers.first { $0.id == "codex" }
                print("LIVE codex status: \(String(describing: codex?.statusMessage)) ready=\(String(describing: codex?.isReady))")
                throw error
            }
            let providers = await recorder.providers
            let codex = try #require(providers.first { $0.id == "codex" }, "T3 lists no codex provider")
            #expect(codex.models.contains { $0.id == "gpt-5.6-luna" })

            // Projects: adding the same path twice returns the same project.
            let project = try await backend.addProject(path: repository.path, title: nil)
            let again = try await backend.addProject(path: repository.path + "/", title: "Other name")
            #expect(project.id == again.id)
            try await waitUntil("the project in the shell", timeout: .seconds(10)) {
                await recorder.projects[project.id] != nil
            }

            // Launch an agent that needs approvals.
            let agentID = try await backend.launchAgent(
                LaunchRequest(
                    projectID: project.id,
                    prompt: "Run the shell command `echo ostra-live` and then append the line `live ok` to README.md. Then reply with the single word: done",
                    providerID: "codex",
                    model: "gpt-5.6-luna",
                    runtimeMode: .approvalRequired
                )
            )
            let launched = try #require(await recorder.agents[agentID], "launchAgent returned before the agent appeared")
            #expect(launched.projectID == project.id)
            #expect(launched.workingDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                == repository.standardizedFileURL.path)

            let conversationTask = Task {
                for await event in backend.conversation(for: agentID) { await recorder.apply(event) }
            }
            defer { conversationTask.cancel() }

            // Approve every request until the run finishes.
            var approved: Set<RequestID> = []
            var sawPrompt = false
            let deadline = ContinuousClock.now + .seconds(240)
            while ContinuousClock.now < deadline {
                let agent = await recorder.agents[agentID]
                if agent?.phase == .done || agent?.phase == .failed { break }
                if agent?.phase == .awaitingApproval, let request = agent?.pendingRequest, !approved.contains(request.id) {
                    // The shell can name the request before the detail stream supplies its
                    // prompt. Give the detail two seconds, then approve regardless.
                    var current = request
                    let promptDeadline = ContinuousClock.now + .seconds(2)
                    while current.prompt == nil, ContinuousClock.now < promptDeadline {
                        try await Task.sleep(for: .milliseconds(25))
                        if let refreshed = await recorder.agents[agentID]?.pendingRequest, refreshed.id == request.id {
                            current = refreshed
                        }
                    }
                    if current.prompt != nil { sawPrompt = true }
                    print("LIVE approving \(current.kind): \(current.prompt ?? "<no prompt>")")
                    approved.insert(current.id)
                    try await backend.respond(to: current.id, of: agentID, decision: .accept)
                }
                try await Task.sleep(for: .milliseconds(50))
            }

            let finished = try #require(await recorder.agents[agentID])
            let timeline = await recorder.sortedTimeline
            print("LIVE timeline:\n" + timeline.map(describe).joined(separator: "\n"))
            print("LIVE meta: \(await recorder.meta)")
            print("LIVE connection history: \(await recorder.connectionHistory)")
            #expect(finished.phase == .done, "phase \(finished.phase), error \(finished.errorMessage ?? "-")")
            #expect(!approved.isEmpty, "the run never asked for approval")
            #expect(sawPrompt, "no pending request carried its prompt")
            #expect(finished.pendingRequest == nil)
            #expect(finished.hasUnseenResult)

            #expect(timeline.contains { if case .userMessage = $0.content { true } else { false } })
            #expect(timeline.contains { if case .assistantMessage = $0.content { true } else { false } })
            #expect(timeline.contains { item in
                if case .approval(let record) = item.content { record.decision == .accept } else { false }
            })
            let command = timeline.first { item in
                if case .command(let call) = item.content { call.command.contains("ostra-live") } else { false }
            }
            let commandItem = try #require(command, "no command row for the echo")
            let output = try await backend.commandOutput(for: agentID, itemID: commandItem.id)
            print("LIVE command output: \(output ?? "<nil>")")
            #expect(output?.contains("ostra-live") == true)

            // The diff covers the file the agent changed.
            let readme = try String(contentsOf: repository.appendingPathComponent("README.md"), encoding: .utf8)
            #expect(readme.contains("live ok"))
            try await waitUntil("a checkpoint", timeout: .seconds(20)) {
                await recorder.meta.completedRunCount > 0
            }
            let diff = try await backend.diff(for: agentID)
            print("LIVE diff:\n\(diff)")
            #expect(diff.contains("+live ok"))
            #expect(await recorder.meta.inputTokens ?? 0 > 0)

            // Visiting clears the unseen result.
            await backend.markVisited(agentID)
            try await waitUntil("the visit to register", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.hasUnseenResult == false
            }

            // A follow-up message starts a second run on the idle thread.
            try await backend.setRuntimeMode(.fullAccess, for: agentID)
            try await backend.sendMessage("Reply with the single word: pong", to: agentID, delivery: .automatic)
            try await waitUntil("the second run to start", timeout: .seconds(30)) {
                await recorder.agents[agentID]?.phase.isActive == true
            }
            try await waitUntil("the second run to finish", timeout: .seconds(120)) {
                let phase = await recorder.agents[agentID]?.phase
                return phase == .done || phase == .failed
            }
            let secondTimeline = await recorder.sortedTimeline
            print("LIVE timeline after follow-up:\n" + secondTimeline.map(describe).joined(separator: "\n"))
            #expect(await recorder.agents[agentID]?.phase == .done)
            #expect(await recorder.agents[agentID]?.runtimeMode == .fullAccess)
            #expect(secondTimeline.contains { item in
                if case .assistantMessage(let text, _) = item.content { text.lowercased().contains("pong") } else { false }
            })

            // Metadata and lifecycle commands.
            try await backend.rename(agentID, title: "Renamed by the live test")
            try await waitUntil("the rename", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.title == "Renamed by the live test"
            }
            try await backend.archive(agentID)
            try await waitUntil("the archive", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.isArchived == true
            }
            try await backend.unarchive(agentID)
            try await waitUntil("the unarchive", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.isArchived == false
            }
            try await backend.delete(agentID)
            try await waitUntil("the delete", timeout: .seconds(10)) {
                await recorder.removedAgents.contains(agentID)
            }
            try await backend.removeProject(project.id)
            try await waitUntil("the project removal", timeout: .seconds(10)) {
                await recorder.projects[project.id] == nil
            }
        } catch {
            print("LIVE failure: \(error)")
            print("LIVE connection history: \(await recorder.connectionHistory)")
            let log = (try? String(contentsOf: support.appendingPathComponent("logs/t3-server.log"), encoding: .utf8)) ?? ""
            print("LIVE server log tail:\n\(log.suffix(3_000))")
            await backend.shutdown()
            throw error
        }

        // Shutdown stops the server this backend started.
        let record = try JSONValue.parse(Data(contentsOf: support.appendingPathComponent("server.json")))
        let pid = Int32(try #require(record.int("pid")))
        #expect(ServerSupervisor.isT3Process(pid))
        await backend.shutdown()
        #expect(!ServerSupervisor.isT3Process(pid))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("server.json").path))
        try? FileManager.default.removeItem(at: support)
        try? FileManager.default.removeItem(at: repository)
    }
}
