import Foundation

/// A simulated engine for demo mode, previews, and tests.
///
/// The mock keeps everything in memory. Agents "work" through a scripted run
/// that streams text, calls tools, and asks for approval, so every UI state
/// is reachable without a provider or a network.
public actor MockBackend: AgentBackend {
    private var eventSinks: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var conversationSinks: [AgentID: [UUID: AsyncStream<ConversationEvent>.Continuation]] = [:]

    private var projects: [Project] = []
    private var agents: [AgentID: AgentSnapshot] = [:]
    private var timelines: [AgentID: [TimelineItem]] = [:]
    private var metas: [AgentID: ConversationMeta] = [:]
    private var runs: [AgentID: Task<Void, Never>] = [:]
    private var decisions: [RequestID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var answers: [RequestID: CheckedContinuation<[String: String], Never>] = [:]
    private var nextOrdinal = 1_000_000
    private var started = false
    private var connection: ConnectionState = .idle

    /// Scales every simulated delay. Tests pass 0 to run scripts instantly.
    private let pace: Double
    private let seeded: Bool

    public init(seeded: Bool = true, pace: Double = 1) {
        self.seeded = seeded
        self.pace = pace
    }

    public static let providers: [ProviderInfo] = [
        ProviderInfo(
            id: "codex",
            name: "Codex",
            isReady: true,
            models: [
                .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", isDefault: true),
                .init(id: "gpt-6-luna", name: "GPT-6 Luna"),
            ]
        ),
        ProviderInfo(
            id: "claudeAgent",
            name: "Claude",
            isReady: true,
            models: [
                .init(id: "claude-fable-5-2", name: "Claude Fable 5.2", isDefault: true),
                .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
            ]
        ),
        ProviderInfo(id: "cursor", name: "Cursor", isReady: false, statusMessage: "Cursor is disabled."),
    ]

    // MARK: - AgentBackend

    public nonisolated func events() -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        let id = UUID()
        continuation.onTermination = { _ in Task { await self.detachEvents(id) } }
        Task { await self.attachEvents(id, continuation) }
        return stream
    }

    public func start() async {
        guard !started else { return }
        started = true
        setConnection(.starting)
        await pause(0.25)
        if seeded { seed() }
        emit(.providers(Self.providers))
        emit(.snapshot(projects: projects, agents: Array(agents.values)))
        setConnection(.ready)
        if seeded { startSeededRuns() }
    }

    public func shutdown() async {
        for task in runs.values { task.cancel() }
        runs.removeAll()
        for sink in eventSinks.values { sink.finish() }
        eventSinks.removeAll()
        for sinks in conversationSinks.values {
            for sink in sinks.values { sink.finish() }
        }
        conversationSinks.removeAll()
    }

    public func addProject(path: String, title: String?) async throws -> Project {
        if let existing = projects.first(where: { $0.path == path }) { return existing }
        let project = Project(
            id: ProjectID(UUID().uuidString),
            title: title ?? (path as NSString).lastPathComponent,
            path: path
        )
        projects.append(project)
        emit(.projectUpserted(project))
        return project
    }

    public func removeProject(_ id: ProjectID) async throws {
        for agent in agents.values where agent.projectID == id {
            try await delete(agent.id)
        }
        projects.removeAll { $0.id == id }
        emit(.projectRemoved(id))
    }

    public func launchAgent(_ request: LaunchRequest) async throws -> AgentID {
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            throw BackendError("The project doesn't exist.")
        }
        let id = AgentID("mock-\(UUID().uuidString.prefix(8))")
        let snapshot = AgentSnapshot(
            id: id,
            projectID: project.id,
            title: request.title ?? Self.title(from: request.prompt),
            providerID: request.providerID,
            model: request.model,
            runtimeMode: request.runtimeMode,
            interactionMode: request.interactionMode,
            phase: .starting,
            branch: "main",
            workingDirectory: project.path
        )
        agents[id] = snapshot
        timelines[id] = []
        metas[id] = ConversationMeta()
        emit(.agentUpserted(snapshot))
        beginRun(id, prompt: request.prompt)
        return id
    }

    public func sendMessage(_ text: String, to agent: AgentID, delivery: MessageDelivery) async throws {
        guard agents[agent] != nil else { throw BackendError("The agent doesn't exist.") }
        if runs[agent] != nil {
            // Steering: the note joins the conversation and the run carries on.
            append(agent, .userMessage(text: text))
            return
        }
        beginRun(agent, prompt: text)
    }

    public func interrupt(_ agent: AgentID) async throws {
        guard let task = runs[agent] else { return }
        task.cancel()
        runs[agent] = nil
        if let request = agents[agent]?.pendingRequest {
            decisions.removeValue(forKey: request.id)?.resume(returning: .cancel)
            answers.removeValue(forKey: request.id)?.resume(returning: [:])
        }
        append(agent, .notice(text: "Stopped by you", level: .info))
        update(agent) {
            $0.phase = .interrupted
            $0.pendingRequest = nil
            $0.activeRunID = nil
        }
    }

    public func respond(to request: RequestID, of agent: AgentID, decision: ApprovalDecision) async throws {
        guard let waiter = decisions.removeValue(forKey: request) else {
            throw BackendError("The request is no longer open.")
        }
        waiter.resume(returning: decision)
    }

    public func answer(request: RequestID, of agent: AgentID, answers given: [String: String]) async throws {
        guard let waiter = answers.removeValue(forKey: request) else {
            throw BackendError("The question is no longer open.")
        }
        waiter.resume(returning: given)
    }

    public func archive(_ agent: AgentID) async throws {
        update(agent) { $0.isArchived = true }
    }

    public func unarchive(_ agent: AgentID) async throws {
        update(agent) { $0.isArchived = false }
    }

    public func delete(_ agent: AgentID) async throws {
        runs[agent]?.cancel()
        runs[agent] = nil
        agents[agent] = nil
        timelines[agent] = nil
        emit(.agentRemoved(agent))
    }

    public func rename(_ agent: AgentID, title: String) async throws {
        update(agent) { $0.title = title }
    }

    public func setRuntimeMode(_ mode: RuntimeMode, for agent: AgentID) async throws {
        update(agent) { $0.runtimeMode = mode }
    }

    public func markVisited(_ agent: AgentID) async {
        update(agent) { $0.lastVisitedAt = .now }
    }

    public nonisolated func conversation(for agent: AgentID) -> AsyncStream<ConversationEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConversationEvent.self)
        let id = UUID()
        continuation.onTermination = { _ in Task { await self.detachConversation(agent, id) } }
        Task { await self.attachConversation(agent, id, continuation) }
        return stream
    }

    public func diff(for agent: AgentID) async throws -> String {
        guard let items = timelines[agent] else { return "" }
        let touched = items.contains { item in
            if case .checkpoint = item.content { return true }
            return false
        }
        return touched ? Self.sampleDiff : ""
    }

    public func commandOutput(for agent: AgentID, itemID: String) async throws -> String? {
        guard let item = timelines[agent]?.first(where: { $0.id == itemID }),
              case let .command(call) = item.content else { return nil }
        return call.output
    }

    // MARK: - Sinks

    private func attachEvents(_ id: UUID, _ continuation: AsyncStream<BackendEvent>.Continuation) {
        eventSinks[id] = continuation
        continuation.yield(.connection(connection))
        if connection.isReady {
            continuation.yield(.providers(Self.providers))
            continuation.yield(.snapshot(projects: projects, agents: Array(agents.values)))
        }
    }

    private func setConnection(_ state: ConnectionState) {
        connection = state
        emit(.connection(state))
    }

    private func detachEvents(_ id: UUID) {
        eventSinks[id] = nil
    }

    private func attachConversation(
        _ agent: AgentID,
        _ id: UUID,
        _ continuation: AsyncStream<ConversationEvent>.Continuation
    ) {
        conversationSinks[agent, default: [:]][id] = continuation
        continuation.yield(.reset(items: timelines[agent] ?? [], meta: metas[agent] ?? ConversationMeta()))
    }

    private func detachConversation(_ agent: AgentID, _ id: UUID) {
        conversationSinks[agent]?[id] = nil
    }

    private func emit(_ event: BackendEvent) {
        for sink in eventSinks.values { sink.yield(event) }
    }

    private func emit(_ agent: AgentID, _ event: ConversationEvent) {
        for sink in (conversationSinks[agent] ?? [:]).values { sink.yield(event) }
    }

    // MARK: - State changes

    private func update(_ id: AgentID, _ change: (inout AgentSnapshot) -> Void) {
        guard var snapshot = agents[id] else { return }
        change(&snapshot)
        snapshot.updatedAt = .now
        agents[id] = snapshot
        emit(.agentUpserted(snapshot))
    }

    @discardableResult
    private func append(
        _ agent: AgentID,
        _ content: TimelineItem.Content,
        status: TimelineItem.Status = .completed
    ) -> String {
        nextOrdinal += 1
        let item = TimelineItem(
            id: "item-\(nextOrdinal)",
            ordinal: nextOrdinal,
            status: status,
            startedAt: .now,
            completedAt: status == .completed ? .now : nil,
            content: content
        )
        timelines[agent, default: []].append(item)
        emit(agent, .upsert(item))
        return item.id
    }

    private func replace(
        _ agent: AgentID,
        _ itemID: String,
        status: TimelineItem.Status,
        _ content: TimelineItem.Content
    ) {
        guard let index = timelines[agent]?.lastIndex(where: { $0.id == itemID }) else { return }
        timelines[agent]![index].content = content
        timelines[agent]![index].status = status
        if status == .completed { timelines[agent]![index].completedAt = .now }
        emit(agent, .upsert(timelines[agent]![index]))
    }

    private func setMeta(_ agent: AgentID, _ change: (inout ConversationMeta) -> Void) {
        var meta = metas[agent] ?? ConversationMeta()
        change(&meta)
        metas[agent] = meta
        emit(agent, .meta(meta))
    }

    private func pause(_ seconds: Double) async {
        guard pace > 0 else {
            await Task.yield()
            return
        }
        try? await Task.sleep(for: .seconds(seconds * pace))
    }

    // MARK: - Scripted runs

    private func beginRun(_ agent: AgentID, prompt: String) {
        runs[agent]?.cancel()
        runs[agent] = Task { [weak self] in
            await self?.run(agent, prompt: prompt)
        }
    }

    private func run(_ agent: AgentID, prompt: String, announce: Bool = true) async {
        if announce { append(agent, .userMessage(text: prompt)) }
        update(agent) {
            $0.phase = .starting
            $0.activeRunID = "run-\(UUID().uuidString.prefix(6))"
            $0.errorMessage = nil
            $0.pendingRequest = nil
        }
        await pause(0.6)
        guard !Task.isCancelled else { return }
        update(agent) { $0.phase = .working }

        let thinking = append(agent, .reasoning(text: "", streaming: true), status: .running)
        await stream(agent, thinking, "Reading the request and locating the relevant code.") { .reasoning(text: $0, streaming: $1) }
        guard !Task.isCancelled else { return }

        let intro = append(agent, .assistantMessage(text: "", streaming: true), status: .running)
        await stream(agent, intro, "I'll start by finding where this lives, then make the change and run the tests.") {
            .assistantMessage(text: $0, streaming: $1)
        }
        guard !Task.isCancelled else { return }

        await command(agent, "rg -n \"session\" Sources --max-count 5", output: """
        Sources/Auth/Session.swift:12:struct Session {
        Sources/Auth/Session.swift:41:    func refresh() async throws {
        Sources/Auth/Redirect.swift:8:    let session: Session
        """)
        guard !Task.isCancelled else { return }

        await pause(0.5)
        let edit = append(agent, .fileChange([.init(path: "Sources/Auth/Redirect.swift", operation: .update)]), status: .running)
        await pause(0.7)
        replace(agent, edit, status: .completed, .fileChange([.init(path: "Sources/Auth/Redirect.swift", operation: .update)]))
        guard !Task.isCancelled else { return }

        if agents[agent]?.runtimeMode != .fullAccess {
            let decision = await requestApproval(agent, command: "swift test --filter AuthTests")
            guard !Task.isCancelled else { return }
            if decision == .decline || decision == .cancel {
                let reply = append(agent, .assistantMessage(text: "", streaming: true), status: .running)
                await stream(agent, reply, "Understood. I made the change and left the tests for you to run.") {
                    .assistantMessage(text: $0, streaming: $1)
                }
                await finish(agent)
                return
            }
        }

        await command(agent, "swift test --filter AuthTests", output: """
        Test Suite 'AuthTests' started.
        ✔ redirectKeepsReturnURL (0.012s)
        ✔ redirectRejectsForeignHosts (0.009s)
        ✔ sessionRefreshesOnce (0.031s)
        Executed 3 tests, with 0 failures in 0.052 seconds
        """)
        guard !Task.isCancelled else { return }

        let summary = append(agent, .assistantMessage(text: "", streaming: true), status: .running)
        await stream(agent, summary, Self.summaryText) { .assistantMessage(text: $0, streaming: $1) }
        await finish(agent)
    }

    private func finish(_ agent: AgentID) async {
        guard !Task.isCancelled else { return }
        append(agent, .checkpoint([
            .init(path: "Sources/Auth/Redirect.swift", additions: 14, deletions: 6),
            .init(path: "Tests/AuthTests/RedirectTests.swift", additions: 27, deletions: 2),
        ]))
        setMeta(agent) {
            $0.contextUsage = min(0.96, ($0.contextUsage ?? 0.18) + 0.13)
            $0.inputTokens = ($0.inputTokens ?? 0) + 41_280
            $0.outputTokens = ($0.outputTokens ?? 0) + 1_912
            $0.completedRunCount += 1
        }
        runs[agent] = nil
        update(agent) {
            $0.phase = .done
            $0.completedAt = .now
            $0.activeRunID = nil
            $0.pendingRequest = nil
        }
    }

    private func stream(
        _ agent: AgentID,
        _ itemID: String,
        _ text: String,
        _ make: (String, Bool) -> TimelineItem.Content
    ) async {
        var shown = ""
        var words = text.split(separator: " ", omittingEmptySubsequences: false)[...]
        while !words.isEmpty {
            guard !Task.isCancelled else { break }
            let chunk = words.prefix(3)
            words = words.dropFirst(3)
            shown += (shown.isEmpty ? "" : " ") + chunk.joined(separator: " ")
            replace(agent, itemID, status: .running, make(shown, true))
            await pause(0.045)
        }
        replace(agent, itemID, status: .completed, make(Task.isCancelled ? shown : text, false))
    }

    private func command(_ agent: AgentID, _ line: String, output: String) async {
        let id = append(agent, .command(.init(command: "/bin/zsh -lc '\(line)'")), status: .running)
        await pause(0.9)
        guard !Task.isCancelled else { return }
        replace(agent, id, status: .completed, .command(.init(command: "/bin/zsh -lc '\(line)'", output: output, exitCode: 0)))
    }

    private func requestApproval(_ agent: AgentID, command: String) async -> ApprovalDecision {
        let requestID = RequestID("req-\(UUID().uuidString.prefix(8))")
        let prompt = "/bin/zsh -lc '\(command)'"
        let item = append(agent, .approval(.init(requestID: requestID, kind: .command, prompt: prompt)), status: .waiting)
        update(agent) {
            $0.phase = .awaitingApproval
            $0.pendingRequest = PendingRequest(id: requestID, kind: .command, prompt: prompt)
        }
        let decision = await withCheckedContinuation { continuation in
            decisions[requestID] = continuation
        }
        replace(agent, item, status: .completed, .approval(.init(requestID: requestID, kind: .command, prompt: prompt, decision: decision)))
        update(agent) {
            $0.phase = .working
            $0.pendingRequest = nil
        }
        return decision
    }

    // MARK: - Seed data

    private func seed() {
        let home = NSHomeDirectory()
        let main = Project(id: ProjectID("proj-ostra"), title: "ostra", path: "\(home)/Developer/ostra")
        let other = Project(id: ProjectID("proj-example"), title: "example-project", path: "\(home)/Developer/example-project")
        projects = [main, other]

        func add(
            _ id: String,
            _ project: Project,
            _ title: String,
            provider: String = "codex",
            model: String = "gpt-6.1-sol",
            phase: AgentPhase,
            age: TimeInterval,
            items: [TimelineItem.Content]
        ) {
            let agentID = AgentID(id)
            agents[agentID] = AgentSnapshot(
                id: agentID,
                projectID: project.id,
                title: title,
                providerID: provider,
                model: model,
                phase: phase,
                branch: "main",
                workingDirectory: project.path,
                createdAt: Date(timeIntervalSinceNow: -age),
                completedAt: phase == .done ? Date(timeIntervalSinceNow: -40) : nil
            )
            timelines[agentID] = []
            metas[agentID] = ConversationMeta(contextUsage: 0.31, inputTokens: 58_200, outputTokens: 3_140, completedRunCount: phase == .done ? 1 : 0)
            for content in items {
                nextOrdinal += 1
                timelines[agentID]!.append(TimelineItem(id: "item-\(nextOrdinal)", ordinal: nextOrdinal, content: content))
            }
        }

        add("mock-john", main, "Plan the onboarding flow", provider: "claudeAgent", model: "claude-fable-5-2", phase: .working, age: 900, items: [
            .userMessage(text: "Plan a first-run onboarding flow for the app. Ask me anything you need first."),
        ])
        add("mock-bob", main, "Fix the auth redirect", phase: .working, age: 800, items: [
            .userMessage(text: "After sign-in we lose the return URL. Fix the redirect and add a test."),
        ])
        add("mock-erica", main, "Refactor the session store", provider: "claudeAgent", model: "claude-sonnet-5-5", phase: .working, age: 700, items: [
            .userMessage(text: "Split SessionStore into a protocol and two implementations."),
        ])
        add("mock-fred", main, "Upgrade dependencies", phase: .idle, age: 600, items: [])
        add("mock-jane", other, "Rebuild the release pipeline", phase: .working, age: 500, items: [
            .userMessage(text: "Clean the dist folder and rebuild the release bundle."),
            .assistantMessage(text: "I'll clear the old build output first, then run the release build.", streaming: false),
        ])
        add("mock-jeff", other, "Write the changelog", provider: "claudeAgent", model: "claude-fable-5-2", phase: .done, age: 400, items: [
            .userMessage(text: "Write the changelog entry for 0.4.0 from the merged PRs."),
            .reasoning(text: "Collecting merged PRs since the last tag.", streaming: false),
            .command(.init(command: "/bin/zsh -lc 'git log v0.3.0..HEAD --oneline'", output: "a41c9d2 Add canvas zoom\n9be01f7 Fix reconnect loop\n51f0c3a Speed up diff parsing", exitCode: 0)),
            .fileChange([.init(path: "CHANGELOG.md", operation: .update)]),
            .assistantMessage(text: Self.changelogText, streaming: false),
            .checkpoint([.init(path: "CHANGELOG.md", additions: 18, deletions: 0)]),
        ])
    }

    private func startSeededRuns() {
        runs[AgentID("mock-john")] = Task { [weak self] in await self?.runQuestion(AgentID("mock-john")) }
        runs[AgentID("mock-bob")] = Task { [weak self] in
            await self?.run(AgentID("mock-bob"), prompt: "", announce: false)
        }
        runs[AgentID("mock-erica")] = Task { [weak self] in await self?.runLongThinking(AgentID("mock-erica")) }
        runs[AgentID("mock-jane")] = Task { [weak self] in await self?.runApprovalOnly(AgentID("mock-jane")) }
    }

    private func runQuestion(_ agent: AgentID) async {
        let intro = append(agent, .assistantMessage(text: "", streaming: true), status: .running)
        await stream(agent, intro, "Before I begin, I need to ask you a couple of questions.") {
            .assistantMessage(text: $0, streaming: $1)
        }
        let requestID = RequestID("req-question")
        let questions = [
            PendingRequest.Question(
                id: "audience",
                header: "Audience",
                prompt: "Who is the onboarding for?",
                choices: [
                    .init(label: "New developers", detail: "Never used an agent harness"),
                    .init(label: "Power users", detail: "Coming from another harness"),
                    .init(label: "Both", detail: "Branch on the first screen"),
                ]
            ),
        ]
        let item = append(agent, .question(.init(requestID: requestID, questions: questions)), status: .waiting)
        update(agent) {
            $0.phase = .awaitingInput
            $0.pendingRequest = PendingRequest(id: requestID, kind: .userInput, questions: questions)
        }
        let given = await withCheckedContinuation { continuation in
            answers[requestID] = continuation
        }
        guard !Task.isCancelled else { return }
        replace(agent, item, status: .completed, .question(.init(requestID: requestID, questions: questions, answers: given)))
        update(agent) {
            $0.phase = .working
            $0.pendingRequest = nil
        }
        let plan = append(agent, .assistantMessage(text: "", streaming: true), status: .running)
        await stream(agent, plan, Self.planText) { .assistantMessage(text: $0, streaming: $1) }
        await finish(agent)
    }

    private func runLongThinking(_ agent: AgentID) async {
        let steps = [
            "Mapping every call site of SessionStore.",
            "Sketching the protocol surface: load, save, invalidate.",
            "Checking which tests construct the store directly.",
            "Drafting the in-memory implementation for tests.",
        ]
        for step in steps {
            guard !Task.isCancelled else { return }
            let id = append(agent, .reasoning(text: "", streaming: true), status: .running)
            await stream(agent, id, step) { .reasoning(text: $0, streaming: $1) }
            await command(agent, "rg -l SessionStore Sources Tests", output: "Sources/Auth/SessionStore.swift\nSources/App/AppModel.swift\nTests/AuthTests/SessionStoreTests.swift")
            await pause(2.4)
        }
        let done = append(agent, .assistantMessage(text: "", streaming: true), status: .running)
        await stream(agent, done, "The split is in place: `SessionStoring`, `KeychainSessionStore`, and `MemorySessionStore`. All 41 tests pass.") {
            .assistantMessage(text: $0, streaming: $1)
        }
        await finish(agent)
    }

    private func runApprovalOnly(_ agent: AgentID) async {
        await pause(1.2)
        let decision = await requestApproval(agent, command: "rm -rf dist && npm run build:release")
        guard !Task.isCancelled else { return }
        if decision == .accept || decision == .acceptForSession || decision == .acceptAlways {
            await command(agent, "rm -rf dist && npm run build:release", output: "> build:release\n> vite build --mode release\n\n✓ 412 modules transformed.\ndist/assets/index-9f2c1e.js  418.22 kB │ gzip: 131.07 kB\n✓ built in 3.84s")
        }
        let reply = append(agent, .assistantMessage(text: "", streaming: true), status: .running)
        await stream(agent, reply, decision == .decline ? "Okay, I left `dist` untouched." : "The release bundle is rebuilt in `dist`.") {
            .assistantMessage(text: $0, streaming: $1)
        }
        await finish(agent)
    }

    // MARK: - Canned text

    private static func title(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }

    static let summaryText = """
    The redirect now keeps the return URL through sign-in.

    **What changed**

    - `Redirect.swift` stores the return URL in the session before the hand-off.
    - Foreign hosts are rejected, so the redirect can't be used as an open relay.
    - Added `RedirectTests` with three cases.

    ```swift
    guard let host = url.host, allowedHosts.contains(host) else {
        return .home
    }
    ```

    All three tests pass. Want me to open a PR?
    """

    static let changelogText = """
    The entry is in `CHANGELOG.md`:

    ## 0.4.0

    - **Canvas zoom**: pinch or hold ⌘ and scroll.
    - **Reconnect**: fixed a loop when the engine restarts.
    - **Diffs**: parsing is about 4x faster on large changes.
    """

    static let planText = """
    Thanks. Here's the plan:

    1. A welcome screen that asks which harness you come from.
    2. A two-step tour for new developers; a keymap import for power users.
    3. A first task that spawns one agent, so the canvas is never empty.

    I'll draft the screens next.
    """

    static let sampleDiff = """
    diff --git a/Sources/Auth/Redirect.swift b/Sources/Auth/Redirect.swift
    index 3f1c2aa..b72e410 100644
    --- a/Sources/Auth/Redirect.swift
    +++ b/Sources/Auth/Redirect.swift
    @@ -6,12 +6,20 @@ import Foundation
     struct Redirect {
         let session: Session
    +    let allowedHosts: Set<String>

    -    func destination(after signIn: SignInResult) -> Destination {
    -        return .home
    +    func destination(after signIn: SignInResult, returnURL: URL?) -> Destination {
    +        guard let url = returnURL else {
    +            return .home
    +        }
    +        guard let host = url.host, allowedHosts.contains(host) else {
    +            return .home
    +        }
    +        session.remember(returnURL: url)
    +        return .url(url)
         }
     }
    diff --git a/Tests/AuthTests/RedirectTests.swift b/Tests/AuthTests/RedirectTests.swift
    new file mode 100644
    index 0000000..9a41c07
    --- /dev/null
    +++ b/Tests/AuthTests/RedirectTests.swift
    @@ -0,0 +1,12 @@
    +import Testing
    +@testable import Auth
    +
    +@Suite struct RedirectTests {
    +    @Test func redirectKeepsReturnURL() {
    +        let redirect = Redirect(session: .fixture, allowedHosts: ["app.example.com"])
    +        let url = URL(string: "https://app.example.com/settings")!
    +        #expect(redirect.destination(after: .ok, returnURL: url) == .url(url))
    +    }
    +}
    """
}
