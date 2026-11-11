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
    /// Per assistant row: the text length and streaming flag of each update, in order.
    var assistantUpdates: [String: [(length: Int, streaming: Bool)]] = [:]

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
            if case .assistantMessage(let text, let streaming) = item.content {
                assistantUpdates[item.id, default: []].append((text.count, streaming))
            }
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
    case .userMessage(let text, _): body = "user: \(text.prefix(60))"
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

    /// An app that Finder launches has a bare `PATH`. The server's `PATH` must
    /// still reach the provider CLIs.
    @Test(.timeLimit(.minutes(1)))
    func resolvesToolDirectoriesFromABarePath() async throws {
        let path = await ServerSupervisor.resolvePath(current: "/usr/bin:/bin")
        let entries = path.split(separator: ":").map(String.init)
        print("LIVE resolved PATH has \(entries.count) entries")
        #expect(entries.contains("/usr/bin"))
        #expect(entries.contains("/opt/homebrew/bin"))
        #expect(entries.contains("\(NSHomeDirectory())/.local/bin"))
        #expect(Set(entries).count == entries.count)
        let codex = entries.contains { FileManager.default.isExecutableFile(atPath: "\($0)/codex") }
        #expect(codex, "codex isn't reachable from the resolved PATH")
    }

    /// Starts and stops the engine twice without running an agent, so it costs nothing.
    @Test(.timeLimit(.minutes(3)))
    func keepsItsCredentialsAcrossRestarts() async throws {
        let support = try Self.makeTemporaryDirectory("restart")
        defer { try? FileManager.default.removeItem(at: support) }
        let tokenFile = support.appendingPathComponent("session-token")

        func runOnce() async throws -> (token: String, states: [ConnectionState]) {
            let backend = T3Backend(configuration: T3Configuration(supportDirectory: support))
            let recorder = Recorder()
            let events = Task {
                for await event in backend.events() { await recorder.apply(event) }
            }
            defer { events.cancel() }
            await backend.start()
            do {
                try await waitUntil("the engine to become ready", timeout: .seconds(90)) {
                    await recorder.connection == .ready
                }
            } catch {
                await backend.shutdown()
                throw error
            }
            let token = try String(contentsOf: tokenFile, encoding: .utf8)
            let permissions = try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600)
            await backend.shutdown()
            try await waitUntil("the idle state", timeout: .seconds(5)) { await recorder.connection == .idle }
            return (token, await recorder.connectionHistory)
        }

        let first = try await runOnce()
        #expect(first.states == [.idle, .starting, .connecting, .ready, .idle])
        #expect(!first.token.isEmpty)

        // The second launch reuses the cached token.
        let second = try await runOnce()
        #expect(second.token == first.token)

        // A token the server doesn't know gets replaced without failing the launch.
        try Data("not-a-real-token".utf8).write(to: tokenFile)
        let third = try await runOnce()
        #expect(third.token != "not-a-real-token")
        #expect(third.token != first.token)
        #expect(!third.states.contains { state in
            if case .failed = state { true } else { false }
        })
    }

    /// Asks the agent to ask a question, then answers it. Whether the model
    /// uses its question tool is up to the model, so this test only runs when
    /// `OSTRA_T3_LIVE_QUESTION=1` is also set.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["OSTRA_T3_LIVE_QUESTION"] == "1"),
        .timeLimit(.minutes(4))
    )
    func answersAQuestion() async throws {
        let support = try Self.makeTemporaryDirectory("question")
        let repository = try Self.makeTemporaryDirectory("question-repo")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: repository)
        }
        let backend = T3Backend(configuration: T3Configuration(supportDirectory: support))
        let recorder = Recorder()
        let events = Task {
            for await event in backend.events() { await recorder.apply(event) }
        }
        defer { events.cancel() }
        await backend.start()
        do {
            try await waitUntil("Codex to become ready", timeout: .seconds(120)) {
                await recorder.providers.first { $0.id == "codex" }?.isReady == true
            }
            let project = try await backend.addProject(path: repository.path, title: nil)
            let agentID = try await backend.launchAgent(
                LaunchRequest(
                    projectID: project.id,
                    prompt: "Before anything else, use your request_user_input tool to ask me exactly one multiple-choice question: which color I prefer, with the options Red and Blue. After I answer, reply with only the color I chose.",
                    providerID: "codex",
                    model: "gpt-5.6-luna",
                    runtimeMode: .fullAccess,
                    interactionMode: .plan
                )
            )
            let conversation = Task {
                for await event in backend.conversation(for: agentID) { await recorder.apply(event) }
            }
            defer { conversation.cancel() }

            try await waitUntil("a question or the end of the run", timeout: .seconds(120)) {
                let agent = await recorder.agents[agentID]
                return agent?.phase == .awaitingInput || agent?.phase == .done || agent?.phase == .failed
            }
            let agent = try #require(await recorder.agents[agentID])
            print("LIVE question phase: \(agent.phase)")
            guard agent.phase == .awaitingInput else {
                print("LIVE question: the model didn't ask. Timeline:\n" + (await recorder.sortedTimeline).map(describe).joined(separator: "\n"))
                await backend.shutdown()
                return
            }
            try await waitUntil("the question's details", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.pendingRequest?.questions.isEmpty == false
            }
            let request = try #require(await recorder.agents[agentID]?.pendingRequest)
            print("LIVE question request: \(request)")
            #expect(request.kind == .userInput)
            let question = try #require(request.questions.first)
            let choice = question.choices.first { $0.label.lowercased().contains("blue") }?.label ?? "Blue"
            try await backend.answer(request: request.id, of: agentID, answers: [question.id: choice])
            try await waitUntil("the run to finish", timeout: .seconds(120)) {
                let phase = await recorder.agents[agentID]?.phase
                return phase == .done || phase == .failed
            }
            let timeline = await recorder.sortedTimeline
            print("LIVE question timeline:\n" + timeline.map(describe).joined(separator: "\n"))
            let record = timeline.compactMap { item -> QuestionRecord? in
                if case .question(let record) = item.content { record } else { nil }
            }.first
            print("LIVE question record: \(String(describing: record))")
            #expect(record?.answers[question.id]?.lowercased().contains("blue") == true)
            #expect(await recorder.agents[agentID]?.phase == .done)
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
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
            try await backend.sendMessage(
                "Reply with the numbers 1 to 80, one per line, and then the single word: pong. Don't run any tools.",
                to: agentID,
                delivery: .automatic
            )
            try await waitUntil("the second run to start", timeout: .seconds(30)) {
                await recorder.agents[agentID]?.phase.isActive == true
            }
            try await waitUntil("the second run to finish", timeout: .seconds(120)) {
                let phase = await recorder.agents[agentID]?.phase
                return phase == .done || phase == .failed
            }
            let secondTimeline = await recorder.sortedTimeline
            print("LIVE timeline after follow-up:\n" + secondTimeline.map(describe).joined(separator: "\n"))
            // Shows whether assistant text grows over several updates or lands whole.
            for (id, updates) in await recorder.assistantUpdates {
                let trace = updates.map { "\($0.length)\($0.streaming ? "s" : "")" }.joined(separator: " ")
                print("LIVE assistant updates \(id.suffix(12)): \(trace)")
            }
            #expect(await recorder.agents[agentID]?.phase == .done)
            #expect(await recorder.agents[agentID]?.runtimeMode == .fullAccess)
            #expect(secondTimeline.contains { item in
                if case .assistantMessage(let text, _) = item.content { text.lowercased().contains("pong") } else { false }
            })

            // Stop interrupts a run that's in the middle of a command.
            try await backend.sendMessage(
                "Run the shell command `sleep 45` and then reply with the single word: finished",
                to: agentID,
                delivery: .automatic
            )
            try await waitUntil("the sleep command to start", timeout: .seconds(60)) {
                await recorder.sortedTimeline.contains { item in
                    if case .command(let call) = item.content { call.command.contains("sleep 45") && item.status == .running } else { false }
                }
            }
            #expect(await recorder.agents[agentID]?.phase == .working)
            try await backend.interrupt(agentID)
            try await waitUntil("the run to stop", timeout: .seconds(30)) {
                await recorder.agents[agentID]?.phase.isActive == false
            }
            print("LIVE phase after interrupt: \(String(describing: await recorder.agents[agentID]?.phase))")
            print("LIVE timeline after interrupt:\n" + (await recorder.sortedTimeline).suffix(5).map(describe).joined(separator: "\n"))
            #expect(await recorder.agents[agentID]?.phase == .interrupted)

            // Metadata.
            try await backend.rename(agentID, title: "Renamed by the live test")
            try await waitUntil("the rename", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.title == "Renamed by the live test"
            }

            // A second backend on the same support directory attaches to the running server.
            let firstRecord = try JSONValue.parse(Data(contentsOf: support.appendingPathComponent("server.json")))
            let firstPID = Int32(try #require(firstRecord.int("pid")))
            let second = T3Backend(configuration: T3Configuration(supportDirectory: support))
            let secondRecorder = Recorder()
            let secondEvents = Task {
                for await event in second.events() { await secondRecorder.apply(event) }
            }
            await second.start()
            try await waitUntil("the second backend to attach", timeout: .seconds(30)) {
                await secondRecorder.connection == .ready
            }
            #expect(await secondRecorder.agents[agentID]?.title == "Renamed by the live test")
            let attachedRecord = try JSONValue.parse(Data(contentsOf: support.appendingPathComponent("server.json")))
            #expect(attachedRecord.int("pid").map(Int32.init) == firstPID, "the second backend spawned its own server")

            // Shutting the second backend down stops the shared server. The first
            // backend notices, starts a new server, and resubscribes.
            let resetsBefore = await recorder.resets
            secondEvents.cancel()
            await second.shutdown()
            #expect(!ServerSupervisor.isT3Process(firstPID))
            try await waitUntil("the first backend to notice the loss", timeout: .seconds(30)) {
                await recorder.connectionHistory.contains { state in
                    if case .reconnecting = state { true } else { false }
                }
            }
            try await waitUntil("the first backend to reconnect", timeout: .seconds(90)) {
                await recorder.connection == .ready
            }
            let newRecord = try JSONValue.parse(Data(contentsOf: support.appendingPathComponent("server.json")))
            #expect(newRecord.int("pid").map(Int32.init) != firstPID)
            #expect(await recorder.agents[agentID]?.title == "Renamed by the live test")
            try await waitUntil("the conversation to reset after the reconnect", timeout: .seconds(30)) {
                await recorder.resets > resetsBefore
            }
            #expect(await recorder.sortedTimeline.count >= secondTimeline.count)
            print("LIVE connection history after reconnect: \(await recorder.connectionHistory)")

            // Lifecycle commands.
            try await backend.archive(agentID)
            try await waitUntil("the archive", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.isArchived == true
            }
            try await backend.unarchive(agentID)
            try await waitUntil("the unarchive", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.isArchived == false
            }
            // An archive that another client made arrives as a bare removal; the
            // bridge looks the thread up to tell it from a delete.
            try await backend.engine.dispatch(T3Commands.archive(threadID: agentID.rawValue))
            try await waitUntil("the foreign archive", timeout: .seconds(10)) {
                await recorder.agents[agentID]?.isArchived == true
            }
            #expect(await !recorder.removedAgents.contains(agentID))
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
