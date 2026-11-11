import Foundation
import OstraCore

/// The state and connection loop behind `T3Backend`.
///
/// The engine keeps the server running, holds one RPC connection, mirrors the
/// server's shell (projects and threads) and the open thread projections, and
/// fans changes out to subscribers. When the connection drops, the loop builds
/// a new one and subscribes again.
actor T3Engine {
    private struct ThreadEntry {
        var shell: JSONValue
        var archived: Bool
    }

    /// One thread's detail subscription and the consumers that share it.
    private struct Hub {
        enum Change {
            case upsert(TimelineItem)
            case remove
        }

        var projection: ThreadProjection
        var consumers: [UUID: AsyncStream<ConversationEvent>.Continuation] = [:]
        /// True while the engine itself needs the projection, for a pending request's details.
        var held = false
        var upstream: Task<Void, Never>?
        var generation = 0
        // Buffered changes. A burst of updates to one item collapses to its latest state.
        var pendingChanges: [String: Change] = [:]
        var pendingOrder: [String] = []
        var pendingMeta: ConversationMeta?
        var flushScheduled = false
        var lastFlush: ContinuousClock.Instant?

        var isWanted: Bool { held || !consumers.isEmpty }
    }

    private let configuration: T3Configuration
    private let installer: RuntimeInstaller
    private let supervisor: ServerSupervisor

    // Mirrored state.
    private var connectionState: ConnectionState = .idle
    private var providers: [ProviderInfo] = []
    private var projects: [String: JSONValue] = [:]
    private var projectOrder: [String] = []
    private var threads: [String: ThreadEntry] = [:]
    private var shellSequence = -1
    /// Archived threads kept from before a reconnect, until the archive query confirms them.
    private var carriedArchive: Set<String> = []
    private var pendingDetails: [String: PendingRequest] = [:]
    private var emittedAgents: [String: AgentSnapshot] = [:]
    /// Counts the updates per thread, so a lookup can tell whether its answer is stale.
    private var threadRevisions: [String: Int] = [:]
    /// Threads this client archived. Their removal from the active list needs no lookup.
    private var expectedArchives: Set<String> = []

    // Subscribers.
    private var subscribers: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var hubs: [String: Hub] = [:]

    // Connection.
    private var connection: RPCConnection?
    private var runTask: Task<Void, Never>?
    private var subscriptionTasks: [Task<Void, Never>] = []
    private var connectionWaiters: [UUID: CheckedContinuation<RPCConnection, Error>] = [:]
    private var isShutDown = true

    /// The shortest gap between two deliveries to a thread's consumers.
    private static let flushInterval: Duration = .milliseconds(33)

    init(configuration: T3Configuration) {
        self.configuration = configuration
        installer = RuntimeInstaller(configuration: configuration)
        supervisor = ServerSupervisor(configuration: configuration)
    }

    // MARK: - Lifecycle

    func start() {
        guard runTask == nil else { return }
        isShutDown = false
        runTask = Task { await self.runLoop() }
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        let loop = runTask
        runTask = nil
        loop?.cancel()
        await dropConnection()
        failConnectionWaiters(BackendError("The engine shut down."))
        // The loop can be mid-spawn. Let it finish so the server it started gets stopped too.
        await loop?.value
        await dropConnection()
        await supervisor.stop()
        setConnection(.idle)
    }

    private func runLoop() async {
        var attempt = 0
        while !isShutDown, !Task.isCancelled {
            do {
                let binary = try await installRuntime()
                setConnection(attempt == 0 ? .starting : .reconnecting(attempt: attempt))
                let endpoint = try await supervisor.ensureRunning(binary: binary)
                if attempt == 0 { setConnection(.connecting) }
                let auth = T3Auth(configuration: configuration, binary: binary)
                let ticket = try await auth.webSocketTicket(for: endpoint)
                let fresh = RPCConnection(url: endpoint.webSocketURL(ticket: ticket))
                try await fresh.open()
                if isShutDown {
                    await fresh.close()
                    break
                }
                connection = fresh
                attempt = 0
                startSubscriptions(on: fresh)
                await fresh.waitUntilClosed()
                await dropConnection()
                if isShutDown { break }
                attempt = 1
                setConnection(.reconnecting(attempt: attempt))
            } catch {
                if isShutDown || Task.isCancelled { break }
                attempt += 1
                setConnection(.failed(message: Self.describe(error)))
            }
            // Back off between attempts: 0.5 s, 1 s, 2 s, up to 15 s.
            let delay = min(0.5 * pow(2, Double(max(attempt - 1, 0))), 15)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func installRuntime() async throws -> URL {
        // Progress callbacks arrive on arbitrary threads; a stream keeps them in order.
        let (updates, continuation) = AsyncStream<ConnectionState>.makeStream()
        let forwarder = Task {
            for await state in updates { self.setConnection(state) }
        }
        defer { continuation.finish() }
        let binary = try await installer.ensureInstalled { message, progress in
            continuation.yield(.preparing(message: message, progress: progress))
        }
        continuation.finish()
        // Let the last progress state land before the loop reports the next phase.
        await forwarder.value
        return binary
    }

    private func dropConnection() async {
        for task in subscriptionTasks { task.cancel() }
        subscriptionTasks.removeAll()
        for id in hubs.keys {
            hubs[id]?.upstream?.cancel()
            hubs[id]?.upstream = nil
            hubs[id]?.generation += 1
        }
        let old = connection
        connection = nil
        await old?.close()
    }

    private func startSubscriptions(on connection: RPCConnection) {
        let config = connection.stream(T3Method.subscribeServerConfig, [:])
        subscriptionTasks.append(
            Task { [weak self] in
                do {
                    for try await item in config { await self?.handleServerConfig(item) }
                } catch {}
            }
        )
        let shell = connection.stream(T3Method.subscribeShell, ["requestCompletionMarker": true])
        subscriptionTasks.append(
            Task { [weak self] in
                do {
                    for try await item in shell { await self?.handleShell(item, on: connection) }
                } catch {}
                // The shell stream is the heartbeat of the session: when it ends, reconnect.
                await connection.close()
            }
        )
        for id in hubs.keys { startUpstream(for: id) }
    }

    // MARK: - Event subscribers

    func addSubscriber(_ id: UUID, _ continuation: AsyncStream<BackendEvent>.Continuation) {
        if cancelledBeforeRegistration.remove(id) != nil {
            continuation.finish()
            return
        }
        subscribers[id] = continuation
        continuation.yield(.connection(connectionState))
        continuation.yield(.providers(providers))
        continuation.yield(.snapshot(projects: currentProjects(), agents: currentAgents()))
    }

    func removeSubscriber(_ id: UUID) {
        if subscribers.removeValue(forKey: id) == nil { cancelledBeforeRegistration.insert(id) }
    }

    private func emit(_ event: BackendEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func setConnection(_ state: ConnectionState) {
        guard state != connectionState else { return }
        connectionState = state
        emit(.connection(state))
    }

    // MARK: - Server config

    private func handleServerConfig(_ item: JSONValue) {
        let next: [ProviderInfo]
        switch item.string("type") {
        case "snapshot":
            guard let config = item["config"] else { return }
            next = T3Mapper.providers(fromServerConfig: config)
        case "providerStatuses":
            guard let payload = item["payload"] else { return }
            next = T3Mapper.providers(fromServerConfig: payload)
        default:
            return
        }
        guard next != providers else { return }
        providers = next
        emit(.providers(next))
    }

    // MARK: - Shell

    private func handleShell(_ item: JSONValue, on connection: RPCConnection) {
        switch item.string("kind") {
        case "snapshot":
            // A snapshot that names resolved repository roots only enriches
            // project metadata. It doesn't carry the thread list.
            guard item["resolvedRepositoryIdentityRoots"] == nil, let snapshot = item["snapshot"] else { return }
            loadShellSnapshot(snapshot)
            loadArchive(from: connection)
        case "project.updated":
            guard advance(to: item), let project = item["project"], let id = project.string("id") else { return }
            applyProject(project, id: id)
        case "project.removed":
            guard advance(to: item), let id = item.string("projectId") else { return }
            removeProject(id)
        case "thread.updated":
            guard advance(to: item), let thread = item["thread"], let id = thread.string("id") else { return }
            applyThread(thread, id: id, archived: item.string("location") == "archive")
        case "thread.removed":
            guard advance(to: item), let id = item.string("threadId") else { return }
            resolveRemoval(of: id, on: connection)
        default:
            break
        }
    }

    /// Handles a thread that left the active list.
    ///
    /// The server reports an archived thread and a deleted thread the same way.
    /// The thread's title still resolves when the thread is archived, so one
    /// lookup tells the two apart.
    private func resolveRemoval(of id: String, on connection: RPCConnection) {
        guard let entry = threads[id] else { return }
        if entry.archived {
            // An archived thread that goes away was deleted.
            removeThread(id)
            return
        }
        if expectedArchives.remove(id) != nil {
            markArchived(id)
            return
        }
        let revision = threadRevisions[id, default: 0]
        subscriptionTasks.append(
            Task { [weak self] in
                let titles = try? await connection.call(T3Method.threadTitles, ["threadIds": [.string(id)]])
                await self?.finishRemoval(of: id, revision: revision, stillExists: titles?[id] != nil)
            }
        )
    }

    private func finishRemoval(of id: String, revision: Int, stillExists: Bool) {
        // An update that arrived during the lookup means the thread is active again.
        guard let entry = threads[id], !entry.archived, threadRevisions[id, default: 0] == revision else { return }
        if stillExists { markArchived(id) } else { removeThread(id) }
    }

    private func markArchived(_ id: String) {
        guard var entry = threads[id] else { return }
        entry.archived = true
        threads[id] = entry
        refreshHold(for: id)
        emitAgent(id)
    }

    /// Accepts a delta when it's newer than the state already applied.
    private func advance(to item: JSONValue) -> Bool {
        guard let sequence = item.int("sequence") else { return true }
        guard sequence > shellSequence else { return false }
        shellSequence = sequence
        return true
    }

    private func loadShellSnapshot(_ snapshot: JSONValue) {
        shellSequence = snapshot.int("snapshotSequence") ?? -1
        projects = [:]
        projectOrder = []
        for project in snapshot.array("projects") {
            guard let id = project.string("id"), !T3Mapper.isProjectHidden(project) else { continue }
            projects[id] = project
            projectOrder.append(id)
        }
        var next: [String: ThreadEntry] = [:]
        for thread in snapshot.array("threads") {
            guard let id = thread.string("id"), thread.nonEmptyString("deletedAt") == nil else { continue }
            next[id] = ThreadEntry(shell: thread, archived: false)
        }
        for thread in snapshot.array("archivedThreads") {
            guard let id = thread.string("id"), thread.nonEmptyString("deletedAt") == nil else { continue }
            next[id] = ThreadEntry(shell: thread, archived: true)
        }
        // Keep archived threads from before a reconnect until the archive query answers.
        carriedArchive = []
        for (id, entry) in threads where entry.archived && next[id] == nil {
            next[id] = entry
            carriedArchive.insert(id)
        }
        threads = next
        for id in Array(pendingDetails.keys) where threads[id] == nil { pendingDetails[id] = nil }
        for id in threads.keys { refreshHold(for: id) }

        let agents = currentAgents()
        emittedAgents = Dictionary(agents.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { _, last in last })
        emit(.snapshot(projects: currentProjects(), agents: agents))
        setConnection(.ready)
        resumeConnectionWaiters()
    }

    /// The shell stream leaves archived threads out. One query fills them in.
    private func loadArchive(from connection: RPCConnection) {
        subscriptionTasks.append(
            Task { [weak self] in
                guard let archive = try? await connection.call(T3Method.archivedShellSnapshot, [:]) else { return }
                await self?.applyArchive(archive)
            }
        )
    }

    private func applyArchive(_ archive: JSONValue) {
        var seen = Set<String>()
        for thread in archive.array("threads") {
            guard let id = thread.string("id"), thread.nonEmptyString("deletedAt") == nil else { continue }
            seen.insert(id)
            // A delta that arrived meanwhile is newer than this query's answer.
            if let existing = threads[id], !existing.archived { continue }
            threads[id] = ThreadEntry(shell: thread, archived: true)
            emitAgent(id)
        }
        for id in carriedArchive where !seen.contains(id) && threads[id]?.archived == true {
            removeThread(id)
        }
        carriedArchive = []
    }

    private func applyProject(_ project: JSONValue, id: String) {
        if T3Mapper.isProjectHidden(project) {
            removeProject(id)
            return
        }
        let previousRoot = projects[id]?.string("workspaceRoot")
        if projects[id] == nil { projectOrder.append(id) }
        projects[id] = project
        if let mapped = T3Mapper.project(project) { emit(.projectUpserted(mapped)) }
        if previousRoot != nil, previousRoot != project.string("workspaceRoot") {
            for (threadID, entry) in threads where entry.shell.string("projectId") == id { emitAgent(threadID) }
        }
    }

    private func removeProject(_ id: String) {
        guard projects.removeValue(forKey: id) != nil else { return }
        projectOrder.removeAll { $0 == id }
        emit(.projectRemoved(ProjectID(id)))
    }

    private func applyThread(_ thread: JSONValue, id: String, archived: Bool) {
        if thread.nonEmptyString("deletedAt") != nil {
            removeThread(id)
            return
        }
        threads[id] = ThreadEntry(shell: thread, archived: archived)
        threadRevisions[id, default: 0] += 1
        refreshHold(for: id)
        emitAgent(id)
    }

    private func removeThread(_ id: String) {
        guard threads.removeValue(forKey: id) != nil else { return }
        pendingDetails[id] = nil
        emittedAgents[id] = nil
        threadRevisions[id] = nil
        expectedArchives.remove(id)
        refreshHold(for: id)
        emit(.agentRemoved(AgentID(id)))
    }

    private func emitAgent(_ id: String) {
        guard let agent = mapAgent(id), emittedAgents[id] != agent else { return }
        emittedAgents[id] = agent
        emit(.agentUpserted(agent))
    }

    private func mapAgent(_ id: String) -> AgentSnapshot? {
        guard let entry = threads[id] else { return nil }
        return T3Mapper.agent(
            entry.shell,
            projectRoots: projectRoots,
            pendingDetail: pendingDetails[id],
            archived: entry.archived
        )
    }

    private var projectRoots: [String: String] {
        projects.compactMapValues { $0.nonEmptyString("workspaceRoot") }
    }

    private func currentProjects() -> [Project] {
        projectOrder.compactMap { projects[$0].flatMap(T3Mapper.project) }
    }

    private func currentAgents() -> [AgentSnapshot] {
        let roots = projectRoots
        return threads
            .compactMap { id, entry in
                T3Mapper.agent(entry.shell, projectRoots: roots, pendingDetail: pendingDetails[id], archived: entry.archived)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Thread hubs

    func addConsumer(_ id: UUID, thread threadID: String, _ continuation: AsyncStream<ConversationEvent>.Continuation) {
        if cancelledBeforeRegistration.remove(id) != nil {
            continuation.finish()
            return
        }
        var hub = hubs[threadID] ?? Hub(projection: ThreadProjection(threadID: threadID))
        hub.consumers[id] = continuation
        if hub.projection.isLoaded {
            continuation.yield(.reset(items: hub.projection.timeline, meta: hub.projection.meta))
        }
        hubs[threadID] = hub
        startUpstream(for: threadID)
    }

    func removeConsumer(_ id: UUID, thread threadID: String) {
        guard hubs[threadID]?.consumers.removeValue(forKey: id) != nil else {
            cancelledBeforeRegistration.insert(id)
            return
        }
        releaseHubIfUnused(threadID)
    }

    /// Keeps a projection alive while its thread waits on the user, so the
    /// agent snapshot can carry the request's prompt and questions.
    private func refreshHold(for threadID: String) {
        let entry = threads[threadID]
        let wantsHold = entry != nil && entry?.archived == false && entry?.shell.object("pendingRuntimeRequest") != nil
        if wantsHold {
            if hubs[threadID] == nil { hubs[threadID] = Hub(projection: ThreadProjection(threadID: threadID)) }
            hubs[threadID]?.held = true
            startUpstream(for: threadID)
            // A projection that's already open knows the request's details now.
            if let detail = hubs[threadID]?.projection.pendingRequest { pendingDetails[threadID] = detail }
        } else {
            pendingDetails[threadID] = nil
            if hubs[threadID]?.held == true {
                hubs[threadID]?.held = false
                releaseHubIfUnused(threadID)
            }
        }
    }

    private func releaseHubIfUnused(_ threadID: String) {
        guard let hub = hubs[threadID], !hub.isWanted else { return }
        hub.upstream?.cancel()
        hubs[threadID] = nil
    }

    private func startUpstream(for threadID: String) {
        guard let connection, let hub = hubs[threadID], hub.upstream == nil, hub.isWanted else { return }
        let generation = hub.generation + 1
        hubs[threadID]?.generation = generation
        // The default encoding sends whole entities, which keeps the reducer small.
        let stream = connection.stream(
            T3Method.subscribeThread,
            ["threadId": .string(threadID), "requestCompletionMarker": true]
        )
        hubs[threadID]?.upstream = Task { [weak self] in
            do {
                for try await item in stream {
                    await self?.handleThreadItem(item, thread: threadID, generation: generation)
                }
            } catch {}
            await self?.upstreamEnded(thread: threadID, generation: generation)
        }
    }

    private func upstreamEnded(thread threadID: String, generation: Int) async {
        guard hubs[threadID]?.generation == generation else { return }
        hubs[threadID]?.upstream = nil
        // The stream ended while the socket is alive, for example because the
        // thread was deleted. Retry after a pause if anyone still listens.
        try? await Task.sleep(for: .seconds(2))
        guard hubs[threadID]?.generation == generation, connection != nil else { return }
        startUpstream(for: threadID)
    }

    private func handleThreadItem(_ item: JSONValue, thread threadID: String, generation: Int) {
        guard var hub = hubs[threadID], hub.generation == generation else { return }
        switch item.string("kind") {
        case "snapshot":
            hub.projection.load(snapshot: item)
            hub.pendingChanges.removeAll()
            hub.pendingOrder.removeAll()
            hub.pendingMeta = nil
            let reset = ConversationEvent.reset(items: hub.projection.timeline, meta: hub.projection.meta)
            for consumer in hub.consumers.values { consumer.yield(reset) }
            hubs[threadID] = hub
        case "event":
            let changes = hub.projection.apply(streamItem: item)
            for change in changes {
                switch change {
                case .upsert(let timelineItem):
                    if hub.pendingChanges[timelineItem.id] == nil { hub.pendingOrder.append(timelineItem.id) }
                    hub.pendingChanges[timelineItem.id] = .upsert(timelineItem)
                case .remove(let id):
                    if hub.pendingChanges[id] == nil { hub.pendingOrder.append(id) }
                    hub.pendingChanges[id] = .remove
                case .meta(let meta):
                    hub.pendingMeta = meta
                case .reset:
                    break
                }
            }
            hubs[threadID] = hub
            if !changes.isEmpty { scheduleFlush(threadID) }
        default:
            return
        }
        updatePendingDetail(for: threadID)
    }

    /// Delivers buffered changes now, or after the rest of the flush interval.
    private func scheduleFlush(_ threadID: String) {
        guard let hub = hubs[threadID], !hub.flushScheduled else { return }
        let now = ContinuousClock.now
        if let last = hub.lastFlush, now - last < Self.flushInterval {
            hubs[threadID]?.flushScheduled = true
            let wait = Self.flushInterval - (now - last)
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                await self?.flush(threadID)
            }
        } else {
            flush(threadID)
        }
    }

    private func flush(_ threadID: String) {
        guard var hub = hubs[threadID] else { return }
        hub.flushScheduled = false
        hub.lastFlush = .now
        var events: [ConversationEvent] = []
        for id in hub.pendingOrder {
            switch hub.pendingChanges[id] {
            case .upsert(let item): events.append(.upsert(item))
            case .remove: events.append(.remove(id: id))
            case nil: continue
            }
        }
        if let meta = hub.pendingMeta { events.append(.meta(meta)) }
        hub.pendingChanges.removeAll(keepingCapacity: true)
        hub.pendingOrder.removeAll(keepingCapacity: true)
        hub.pendingMeta = nil
        hubs[threadID] = hub
        for consumer in hub.consumers.values {
            for event in events { consumer.yield(event) }
        }
    }

    /// Copies the pending request's details from the projection to the agent snapshot.
    ///
    /// The detail stream and the shell stream race: either can report a new
    /// request first. The mapper matches the detail to the shell's request by
    /// ID, so a detail that arrives early waits until the shell names it.
    private func updatePendingDetail(for threadID: String) {
        guard let hub = hubs[threadID], hub.projection.isLoaded else { return }
        let detail = hub.projection.pendingRequest
        guard pendingDetails[threadID] != detail else { return }
        pendingDetails[threadID] = detail
        emitAgent(threadID)
    }

    // MARK: - Commands

    func addProject(path: String, title: String?) async throws -> Project {
        let connection = try await liveConnection()
        let normalized = Self.normalize(path)
        if let existing = projectOrder.compactMap({ projects[$0] }).first(where: {
            $0.string("workspaceRoot").map(Self.normalize) == normalized
        }), let mapped = T3Mapper.project(existing) {
            return mapped
        }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = T3Commands.createProject(
            projectID: T3Commands.newID(),
            title: (name?.isEmpty == false ? name : nil) ?? URL(fileURLWithPath: normalized).lastPathComponent,
            path: normalized
        )
        let created = try await call(connection, T3Method.mutateProject, command)
        guard let project = T3Mapper.project(created), let id = created.string("id") else {
            throw BackendError("The engine created the project but sent an unreadable record.")
        }
        // The shell stream reports the project too; applying it now makes it usable at once.
        if projects[id] == nil {
            projects[id] = created
            projectOrder.append(id)
            emit(.projectUpserted(project))
        }
        return project
    }

    func removeProject(_ id: ProjectID, force: Bool) async throws {
        let connection = try await liveConnection()
        _ = try await call(connection, T3Method.mutateProject, T3Commands.deleteProject(projectID: id.rawValue, force: force))
    }

    func launchAgent(_ request: LaunchRequest) async throws -> AgentID {
        let connection = try await liveConnection()
        let result = try await call(connection, T3Method.launchThread, T3Commands.launchThread(request))
        guard let threadID = result.string("threadId") else {
            throw BackendError("The engine started the agent but didn't return its ID.")
        }
        // The shell stream announces the thread. Wait for it briefly so the
        // caller can select the agent as soon as this returns.
        let deadline = ContinuousClock.now + .seconds(3)
        while threads[threadID] == nil, ContinuousClock.now < deadline, self.connection != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return AgentID(threadID)
    }

    func dispatch(_ command: JSONValue) async throws {
        let connection = try await liveConnection()
        _ = try await call(connection, T3Method.dispatchCommand, command)
    }

    func archive(thread threadID: String) async throws {
        // The shell reports the archive as a removal; remember that this one is an archive.
        expectedArchives.insert(threadID)
        do {
            try await dispatch(T3Commands.archive(threadID: threadID))
        } catch {
            expectedArchives.remove(threadID)
            throw error
        }
    }

    func answer(request: RequestID, thread threadID: String, answers: [String: String]) async throws {
        let connection = try await liveConnection()
        var questions = hubs[threadID]?.projection.wireQuestions(for: request.rawValue) ?? []
        if questions.isEmpty {
            let projection = try await call(connection, T3Method.threadProjection, ["threadId": .string(threadID)])
            questions = projection.array("turnItems")
                .first { $0.string("requestId") == request.rawValue }?
                .array("questions") ?? []
        }
        let command = T3Commands.answer(
            threadID: threadID,
            requestID: request.rawValue,
            answers: T3Mapper.wireAnswers(answers, questions: questions)
        )
        _ = try await call(connection, T3Method.dispatchCommand, command)
    }

    func diff(thread threadID: String) async throws -> String {
        let connection = try await liveConnection()
        var turnCount = 0
        if let hub = hubs[threadID], hub.projection.isLoaded {
            turnCount = hub.projection.latestCheckpointTurnCount
        } else {
            let projection = try await call(connection, T3Method.threadProjection, ["threadId": .string(threadID)])
            turnCount = projection.array("checkpoints").compactMap { $0.int("appRunOrdinal") }.max() ?? 0
        }
        guard turnCount > 0 else { return "" }
        let result = try await call(
            connection,
            T3Method.fullThreadDiff,
            ["threadId": .string(threadID), "toTurnCount": .number(Double(turnCount))]
        )
        return result.string("diff") ?? ""
    }

    func commandOutput(thread threadID: String, itemID: String) async throws -> String? {
        let connection = try await liveConnection()
        let result = try await call(
            connection,
            T3Method.turnItem,
            ["threadId": .string(threadID), "itemId": .string(itemID)]
        )
        guard let item = result["item"], !item.isNull else { return nil }
        return item.string("output") ?? T3Mapper.readableText(item["output"])
    }

    private func call(_ connection: RPCConnection, _ method: String, _ payload: JSONValue) async throws -> JSONValue {
        do {
            return try await connection.call(method, payload)
        } catch {
            throw BackendError(Self.describe(error))
        }
    }

    // MARK: - Waiting for a connection

    /// Returns the connection once the shell is synchronized. Waits through a
    /// startup or a reconnect, and fails after 20 seconds.
    private func liveConnection() async throws -> RPCConnection {
        if let connection, connectionState.isReady { return connection }
        guard !isShutDown else { throw BackendError("The engine isn't running.") }
        let id = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { return }
            await self?.failConnectionWaiter(id, BackendError("The engine isn't connected."))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connectionWaiters[id] = continuation
        }
    }

    private func resumeConnectionWaiters() {
        guard let connection else { return }
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(returning: connection) }
    }

    private func failConnectionWaiter(_ id: UUID, _ error: Error) {
        connectionWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failConnectionWaiters(_ error: Error) {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: error) }
    }

    // MARK: - Helpers

    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? BackendError { return error.message }
        if let error = error as? RPCError { return error.message }
        return error.localizedDescription
    }
}
