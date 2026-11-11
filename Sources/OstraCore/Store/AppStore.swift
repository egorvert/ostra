import CoreGraphics
import Foundation
import Observation

/// The app's state: what the engine reports, plus selection, layout, and spawn defaults.
///
/// Views read the store and call its actions. The store owns the engine
/// subscriptions and never exposes the engine's wire types.
@MainActor @Observable
public final class AppStore {
    public let backend: any AgentBackend

    // MARK: Engine state

    public private(set) var connection: ConnectionState = .idle
    public private(set) var providers: [ProviderInfo] = []
    public private(set) var projects: [Project] = []
    /// Agents on the canvas, oldest first. Archived agents and subagents aren't here.
    public private(set) var agents: [AgentModel] = []
    public private(set) var archivedAgents: [AgentSnapshot] = []
    /// True once the engine delivered its first snapshot.
    public private(set) var hasLoaded = false

    // MARK: Selection

    public private(set) var selectedAgentID: AgentID?
    /// The agent in the second chat column, when the chat is split.
    public private(set) var pinnedAgentID: AgentID?
    /// Where new agents spawn.
    public var currentProjectID: ProjectID? { didSet { schedulePersist() } }
    public var cycleFilter: CycleFilter = .all { didSet { schedulePersist() } }
    /// True while search needs every agent's conversation, not only the ones in view.
    public var loadsEveryConversation = false {
        didSet {
            if loadsEveryConversation != oldValue { refreshConversations() }
        }
    }

    // MARK: Spawn defaults

    public var spawnProviderID: String? { didSet { schedulePersist() } }
    public var spawnModelID: String? { didSet { schedulePersist() } }
    public var spawnMode: RuntimeMode = .autoAcceptEdits { didSet { schedulePersist() } }

    // MARK: Canvas

    public var camera = CameraState() { didSet { schedulePersist() } }
    public private(set) var projectAnchors: [ProjectID: CGPoint] = [:]

    // MARK: Feedback

    public private(set) var toasts: [Toast] = []

    @ObservationIgnored private var index: [AgentID: AgentModel] = [:]
    @ObservationIgnored private var hiddenAgents: [AgentID: AgentSnapshot] = [:]
    @ObservationIgnored private var persisted = PersistedState()
    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var conversationTasks: [AgentID: Task<Void, Never>] = [:]
    @ObservationIgnored private var recentSelections: [AgentID] = []
    @ObservationIgnored private var toastActions: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var pendingSelection: AgentID?
    @ObservationIgnored private var isRestoring = false

    public init(backend: any AgentBackend, persistenceURL: URL? = nil) {
        self.backend = backend
        self.persistenceURL = persistenceURL
        restore()
    }

    // MARK: - Lifecycle

    /// Starts the engine and begins applying its events.
    public func start() {
        guard eventTask == nil else { return }
        let backend = backend
        eventTask = Task { [weak self] in
            for await event in backend.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
        Task { await backend.start() }
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        for task in conversationTasks.values { task.cancel() }
        conversationTasks.removeAll()
        persistNow()
        await backend.shutdown()
    }

    // MARK: - Lookups

    public func agent(_ id: AgentID?) -> AgentModel? {
        guard let id else { return nil }
        return index[id]
    }

    public var selectedAgent: AgentModel? { agent(selectedAgentID) }
    public var pinnedAgent: AgentModel? { agent(pinnedAgentID) }

    public func project(_ id: ProjectID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public var currentProject: Project? {
        project(currentProjectID) ?? projects.first
    }

    public func agents(in project: ProjectID) -> [AgentModel] {
        agents.filter { $0.projectID == project }
    }

    public func provider(_ id: String?) -> ProviderInfo? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    /// The provider new agents use: the user's pick when it's ready, else the first ready one.
    public var spawnProvider: ProviderInfo? {
        if let picked = provider(spawnProviderID), picked.isReady { return picked }
        return providers.first(where: \.isReady)
    }

    public var spawnModel: ProviderInfo.Model? {
        guard let provider = spawnProvider else { return nil }
        return provider.models.first { $0.id == spawnModelID } ?? provider.defaultModel
    }

    public var attentionCount: Int { agents.count(where: \.needsAttention) }
    public var runningCount: Int { agents.count(where: { $0.phase.isRunning }) }

    /// The frame of a project's group on the canvas.
    public func groupFrame(for project: ProjectID) -> CGRect {
        let anchor = projectAnchors[project] ?? .zero
        return CanvasLayout.groupFrame(members: agents(in: project).map(\.position), anchor: anchor)
    }

    /// The rectangle that contains every group.
    public var contentBounds: CGRect? {
        let frames = projects.filter { projectAnchors[$0.id] != nil }.map { groupFrame(for: $0.id) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - Selection

    public func select(_ id: AgentID?) {
        guard id != selectedAgentID else { return }
        selectedAgentID = id
        if let agent = agent(id) {
            currentProjectID = agent.projectID
            recentSelections.removeAll { $0 == agent.id }
            recentSelections.append(agent.id)
            if recentSelections.count > 4 { recentSelections.removeFirst() }
            markVisited(agent)
        }
        if id != nil, id == pinnedAgentID { pinnedAgentID = nil }
        refreshConversations()
    }

    /// Pins an agent in the second chat column, or clears the pin with nil.
    public func pin(_ id: AgentID?) {
        pinnedAgentID = id == selectedAgentID ? nil : id
        refreshConversations()
    }

    /// Swaps the selected agent and the pinned agent.
    public func swapPinned() {
        guard let pinned = pinnedAgentID, let selected = selectedAgentID else { return }
        pinnedAgentID = nil
        select(pinned)
        pinnedAgentID = selected
        refreshConversations()
    }

    /// The agents the cycle keys visit, in visiting order.
    public var cycleCandidates: [AgentModel] {
        let ordered = canvasOrder
        switch cycleFilter {
        case .all: return ordered
        case .attention: return ordered.filter(\.needsAttention)
        case .running: return ordered.filter { $0.phase.isActive }
        }
    }

    /// Agents grouped by project, then by age.
    public var canvasOrder: [AgentModel] {
        let rank = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($1.id, $0) })
        return agents.sorted { a, b in
            let ra = rank[a.projectID] ?? .max
            let rb = rank[b.projectID] ?? .max
            if ra != rb { return ra < rb }
            return a.snapshot.createdAt < b.snapshot.createdAt
        }
    }

    /// Selects the next or previous agent in the cycle set.
    @discardableResult
    public func cycle(forward: Bool) -> AgentModel? {
        let candidates = cycleCandidates.filter { $0.id != pinnedAgentID }
        guard !candidates.isEmpty else { return nil }
        let next: AgentModel
        if let current = candidates.firstIndex(where: { $0.id == selectedAgentID }) {
            let count = candidates.count
            next = candidates[(current + (forward ? 1 : count - 1)) % count]
        } else {
            next = forward ? candidates[0] : candidates[candidates.count - 1]
        }
        select(next.id)
        return next
    }

    /// Selects the nearest agent in a direction on the canvas.
    @discardableResult
    public func selectNeighbor(_ direction: CGVector) -> AgentModel? {
        guard let current = selectedAgent else {
            let first = canvasOrder.first
            select(first?.id)
            return first
        }
        let others = agents.filter { $0.id != current.id }.map { (id: $0.id, position: $0.position) }
        guard let id = CanvasLayout.neighbor(from: current.position, direction: direction, candidates: others) else {
            return nil
        }
        select(id)
        return agent(id)
    }

    // MARK: - Actions

    /// Creates an agent in the current project with `prompt` as its first message.
    public func spawn(prompt: String, attachments: [Attachment] = []) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let project = currentProject else {
            toast(.init(kind: .error, text: "Add a project folder first."))
            return
        }
        guard let provider = spawnProvider, let model = spawnModel else {
            toast(.init(kind: .error, text: "No provider is ready. Sign in to Codex or Claude, then try again."))
            return
        }
        let mode = provider.supports(spawnMode)
            ? spawnMode
            : (provider.supportedRuntimeModes.first ?? spawnMode)
        let request = LaunchRequest(
            projectID: project.id,
            prompt: text,
            attachments: attachments,
            providerID: provider.id,
            model: model.id,
            runtimeMode: mode
        )
        run("Couldn't start the agent") { store in
            let id = try await store.backend.launchAgent(request)
            if store.agent(id) != nil {
                store.select(id)
            } else {
                store.pendingSelection = id
            }
        }
    }

    /// Sends text to an agent. If the agent waits on a question, the text answers it.
    public func send(_ text: String, attachments: [Attachment] = [], to id: AgentID, queue: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, let agent = agent(id) else { return }
        if attachments.isEmpty, agent.phase == .awaitingInput, let request = agent.snapshot.pendingRequest,
           let question = request.questions.first, request.questions.count == 1 {
            answer(request: request.id, of: id, answers: [question.id: trimmed])
            return
        }
        run("Couldn't send the message") { store in
            try await store.backend.sendMessage(
                trimmed,
                attachments: attachments,
                to: id,
                delivery: queue ? .queue : .automatic
            )
        }
    }

    public func respond(_ decision: ApprovalDecision, to id: AgentID) {
        guard let request = agent(id)?.snapshot.pendingRequest else { return }
        run("Couldn't send the decision") { store in
            try await store.backend.respond(to: request.id, of: id, decision: decision)
        }
    }

    public func answer(request: RequestID, of id: AgentID, answers: [String: String]) {
        run("Couldn't send the answer") { store in
            try await store.backend.answer(request: request, of: id, answers: answers)
        }
    }

    public func interrupt(_ id: AgentID) {
        guard agent(id)?.phase.isActive == true else { return }
        run("Couldn't stop the agent") { store in
            try await store.backend.interrupt(id)
        }
    }

    /// Archives an agent and offers to undo.
    public func archive(_ id: AgentID) {
        guard let agent = agent(id) else { return }
        let name = agent.name
        if selectedAgentID == id {
            // Move on to a neighbor so the keyboard keeps a target.
            let candidates = canvasOrder.filter { $0.id != id && $0.id != pinnedAgentID }
            if let position = canvasOrder.firstIndex(where: { $0.id == id }), !candidates.isEmpty {
                select(candidates[min(position, candidates.count - 1)].id)
            } else {
                select(nil)
            }
        }
        if pinnedAgentID == id { pinnedAgentID = nil }
        run("Couldn't archive \(name)") { store in
            if store.agent(id)?.phase.isActive == true {
                try? await store.backend.interrupt(id)
            }
            try await store.backend.archive(id)
            store.toast(.init(kind: .info, text: "Archived \(name)", actionLabel: "Undo")) { [weak store] in
                store?.restore(id)
            }
        }
    }

    /// Brings an archived agent back to the canvas.
    public func restore(_ id: AgentID) {
        run("Couldn't restore the agent") { store in
            try await store.backend.unarchive(id)
        }
    }

    /// Deletes an agent and its conversation for good.
    public func delete(_ id: AgentID) {
        let name = agent(id)?.name ?? "the agent"
        if selectedAgentID == id { select(nil) }
        if pinnedAgentID == id { pinnedAgentID = nil }
        run("Couldn't delete \(name)") { store in
            if store.agent(id)?.phase.isActive == true {
                try? await store.backend.interrupt(id)
            }
            try await store.backend.delete(id)
        }
    }

    public func rename(_ id: AgentID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let agent = agent(id) else { return }
        agent.name = trimmed
        persisted.names[id.rawValue] = trimmed
        schedulePersist()
    }

    public func setRuntimeMode(_ mode: RuntimeMode, for id: AgentID) {
        run("Couldn't change permissions") { store in
            try await store.backend.setRuntimeMode(mode, for: id)
        }
    }

    public func addProject(path: String) {
        run("Couldn't add the project") { store in
            let project = try await store.backend.addProject(path: path, title: nil)
            store.currentProjectID = project.id
        }
    }

    public func removeProject(_ id: ProjectID) {
        run("Couldn't remove the project") { store in
            try await store.backend.removeProject(id)
        }
    }

    /// Moves an agent's card.
    public func move(_ id: AgentID, to position: CGPoint) {
        guard let agent = agent(id) else { return }
        agent.position = position
        persisted.positions[id.rawValue] = position
        schedulePersist()
    }

    /// Tells the engine the user saw the agent's latest result.
    public func markVisited(_ agent: AgentModel) {
        guard agent.snapshot.hasUnseenResult else { return }
        agent.snapshot.lastVisitedAt = .now
        let backend = backend
        let id = agent.id
        Task { await backend.markVisited(id) }
    }

    // MARK: - Toasts

    public func toast(_ toast: Toast, action: (@MainActor () -> Void)? = nil) {
        toasts.append(toast)
        if toasts.count > 3 { dismissToast(toasts[0].id) }
        if let action { toastActions[toast.id] = action }
        let id = toast.id
        let lifetime: Duration = toast.actionLabel == nil ? .seconds(3.5) : .seconds(6)
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.dismissToast(id)
        }
    }

    public func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        toastActions[id] = nil
    }

    /// Runs the newest toast's action, such as Undo. Returns false when no toast has one.
    @discardableResult
    public func performToastAction(_ id: UUID? = nil) -> Bool {
        guard let target = id ?? toasts.last(where: { $0.actionLabel != nil })?.id,
              let action = toastActions[target] else { return false }
        dismissToast(target)
        action()
        return true
    }

    // MARK: - Engine events

    func handle(_ event: BackendEvent) {
        switch event {
        case let .connection(state):
            connection = state
        case let .providers(list):
            providers = list
        case let .snapshot(newProjects, snapshots):
            applySnapshot(projects: newProjects, snapshots: snapshots)
        case let .projectUpserted(project):
            if let existing = projects.firstIndex(where: { $0.id == project.id }) {
                projects[existing] = project
            } else {
                projects.append(project)
                assignAnchor(for: project.id)
            }
            if currentProjectID == nil { currentProjectID = project.id }
        case let .projectRemoved(id):
            projects.removeAll { $0.id == id }
            projectAnchors[id] = nil
            if currentProjectID == id { currentProjectID = projects.first?.id }
        case let .agentUpserted(snapshot):
            upsert(snapshot)
            refreshConversations()
        case let .agentRemoved(id):
            remove(id)
            archivedAgents.removeAll { $0.id == id }
            hiddenAgents[id] = nil
            refreshConversations()
        }
    }

    private func applySnapshot(projects newProjects: [Project], snapshots: [AgentSnapshot]) {
        projects = newProjects
        let known = Set(newProjects.map(\.id))
        for id in projectAnchors.keys where !known.contains(id) {
            projectAnchors[id] = nil
        }

        let incoming = Set(snapshots.map(\.id))
        for agent in agents where !incoming.contains(agent.id) {
            remove(agent.id)
        }
        archivedAgents.removeAll()
        hiddenAgents.removeAll()

        // Lay out one project at a time, so each new group lands clear of the
        // groups before it at their real size.
        let byProject = Dictionary(grouping: snapshots, by: \.projectID)
        for project in newProjects {
            if projectAnchors[project.id] == nil { assignAnchor(for: project.id) }
            for snapshot in (byProject[project.id] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
                upsert(snapshot)
            }
        }
        for snapshot in snapshots where !known.contains(snapshot.projectID) {
            upsert(snapshot)
        }

        if currentProjectID == nil || project(currentProjectID) == nil {
            currentProjectID = newProjects.first?.id
        }
        if let selected = selectedAgentID, index[selected] == nil { selectedAgentID = nil }
        if let pinned = pinnedAgentID, index[pinned] == nil { pinnedAgentID = nil }
        hasLoaded = true
        refreshConversations()
    }

    private func upsert(_ snapshot: AgentSnapshot) {
        if snapshot.isArchived {
            remove(snapshot.id)
            if let existing = archivedAgents.firstIndex(where: { $0.id == snapshot.id }) {
                archivedAgents[existing] = snapshot
            } else {
                archivedAgents.append(snapshot)
            }
            return
        }
        archivedAgents.removeAll { $0.id == snapshot.id }

        if snapshot.parentID != nil {
            // Subagents live inside their parent's conversation, not on the canvas.
            hiddenAgents[snapshot.id] = snapshot
            return
        }

        if let agent = index[snapshot.id] {
            let before = agent.snapshot
            // Keep a local visit mark until the engine catches up with it.
            var merged = snapshot
            if let local = before.lastVisitedAt, (merged.lastVisitedAt ?? .distantPast) < local {
                merged.lastVisitedAt = local
            }
            if before != merged { agent.snapshot = merged }
            refreshLiveLine(agent)
            // The user is looking at the selected agent, so its result is seen.
            if agent.id == selectedAgentID { markVisited(agent) }
            return
        }

        let name = persisted.names[snapshot.id.rawValue]
            ?? AgentNames.pick(for: snapshot.id, taken: Set(agents.map(\.name)))
        if projectAnchors[snapshot.projectID] == nil { assignAnchor(for: snapshot.projectID) }
        let saved = persisted.positions[snapshot.id.rawValue]
        let position = saved ?? CanvasLayout.freeSlot(
            anchor: projectAnchors[snapshot.projectID] ?? .zero,
            occupied: agents(in: snapshot.projectID).map(\.position)
        )
        let agent = AgentModel(snapshot: snapshot, name: name, position: position)
        index[snapshot.id] = agent
        agents.append(agent)
        persisted.names[snapshot.id.rawValue] = name
        persisted.positions[snapshot.id.rawValue] = position
        // A group that grew may now reach into its neighbors.
        if saved == nil { makeRoom(around: snapshot.projectID) }
        schedulePersist()

        if pendingSelection == snapshot.id {
            pendingSelection = nil
            select(snapshot.id)
        }
    }

    private func remove(_ id: AgentID) {
        guard index[id] != nil else { return }
        index[id] = nil
        agents.removeAll { $0.id == id }
        conversationTasks[id]?.cancel()
        conversationTasks[id] = nil
        recentSelections.removeAll { $0 == id }
        if selectedAgentID == id { selectedAgentID = nil }
        if pinnedAgentID == id { pinnedAgentID = nil }
    }

    private func assignAnchor(for project: ProjectID) {
        if let saved = persisted.projectAnchors[project.rawValue] {
            projectAnchors[project] = saved
            return
        }
        let frames = projects
            .filter { $0.id != project && projectAnchors[$0.id] != nil }
            .map { groupFrame(for: $0.id) }
        let anchor = CanvasLayout.nextProjectAnchor(existing: frames)
        projectAnchors[project] = anchor
        persisted.projectAnchors[project.rawValue] = anchor
        schedulePersist()
    }

    /// Pushes other groups away from a group that grew.
    private func makeRoom(around project: ProjectID, depth: Int = 0) {
        guard depth < 8 else { return }
        let margin = CanvasLayout.groupGap * 0.6
        let frame = groupFrame(for: project)
        // A project without an anchor isn't on the canvas yet, so it can't collide.
        for other in projects where other.id != project && projectAnchors[other.id] != nil {
            let otherFrame = groupFrame(for: other.id)
            guard frame.insetBy(dx: -margin, dy: -margin).intersects(otherFrame) else { continue }
            let horizontal = otherFrame.midX >= frame.midX
                ? frame.maxX + CanvasLayout.groupGap - otherFrame.minX
                : frame.minX - CanvasLayout.groupGap - otherFrame.maxX
            let vertical = otherFrame.midY >= frame.midY
                ? frame.maxY + CanvasLayout.groupGap - otherFrame.minY
                : frame.minY - CanvasLayout.groupGap - otherFrame.maxY
            let shift = abs(horizontal) <= abs(vertical)
                ? CGVector(dx: horizontal, dy: 0)
                : CGVector(dx: 0, dy: vertical)
            moveGroup(other.id, by: shift)
            makeRoom(around: other.id, depth: depth + 1)
        }
    }

    /// Moves a project's group and every agent in it.
    public func moveGroup(_ project: ProjectID, by delta: CGVector) {
        if let anchor = projectAnchors[project] {
            let moved = CGPoint(x: anchor.x + delta.dx, y: anchor.y + delta.dy)
            projectAnchors[project] = moved
            persisted.projectAnchors[project.rawValue] = moved
        }
        for agent in agents(in: project) {
            let moved = CGPoint(x: agent.position.x + delta.dx, y: agent.position.y + delta.dy)
            agent.position = moved
            persisted.positions[agent.id.rawValue] = moved
        }
        schedulePersist()
    }

    // MARK: - Conversations

    /// Keeps live conversations for the agents the user looks at and the agents at work.
    private func refreshConversations() {
        var wanted = Set<AgentID>()
        if let selectedAgentID { wanted.insert(selectedAgentID) }
        if let pinnedAgentID { wanted.insert(pinnedAgentID) }
        wanted.formUnion(recentSelections)
        for agent in agents where agent.phase.isActive || loadsEveryConversation {
            wanted.insert(agent.id)
        }
        wanted = wanted.filter { index[$0] != nil }

        for (id, task) in conversationTasks where !wanted.contains(id) {
            task.cancel()
            conversationTasks[id] = nil
        }
        for id in wanted where conversationTasks[id] == nil {
            guard let agent = index[id] else { continue }
            let backend = backend
            conversationTasks[id] = Task { [weak self, weak agent] in
                for await event in backend.conversation(for: id) {
                    guard let self, let agent else { return }
                    agent.conversation.apply(event)
                    self.conversationChanged(agent, event: event)
                }
            }
        }
    }

    private func conversationChanged(_ agent: AgentModel, event: ConversationEvent) {
        refreshLiveLine(agent)
        switch event {
        case .reset:
            refreshChanges(agent)
        case let .upsert(item):
            if case .checkpoint = item.content { refreshChanges(agent) }
        case .remove, .meta:
            break
        }
        // A result that lands while the user watches the agent counts as seen.
        if agent.id == selectedAgentID { markVisited(agent) }
    }

    private func refreshLiveLine(_ agent: AgentModel) {
        let line = LiveLine.derive(snapshot: agent.snapshot, items: agent.conversation.items)
        if agent.liveLine != line { agent.liveLine = line }
    }

    private func refreshChanges(_ agent: AgentModel) {
        var perFile: [String: (additions: Int, deletions: Int)] = [:]
        for item in agent.conversation.items {
            guard case let .checkpoint(files) = item.content else { continue }
            for file in files {
                let current = perFile[file.path] ?? (0, 0)
                perFile[file.path] = (current.additions + file.additions, current.deletions + file.deletions)
            }
        }
        let stats = ChangeStats(
            files: perFile.count,
            additions: perFile.values.reduce(0) { $0 + $1.additions },
            deletions: perFile.values.reduce(0) { $0 + $1.deletions }
        )
        if agent.changes != stats { agent.changes = stats }
    }

    // MARK: - Persistence

    private func restore() {
        guard let persistenceURL, let data = try? Data(contentsOf: persistenceURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        isRestoring = true
        persisted = state
        camera = state.camera
        currentProjectID = state.currentProjectID.map(ProjectID.init)
        cycleFilter = state.cycleFilter
        spawnProviderID = state.spawnProviderID
        spawnModelID = state.spawnModelID
        spawnMode = state.spawnMode
        for (key, anchor) in state.projectAnchors {
            projectAnchors[ProjectID(key)] = anchor
        }
        isRestoring = false
    }

    private func schedulePersist() {
        guard persistenceURL != nil, !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    public func persistNow() {
        guard let persistenceURL else { return }
        persisted.camera = camera
        persisted.currentProjectID = currentProjectID?.rawValue
        persisted.cycleFilter = cycleFilter
        persisted.spawnProviderID = spawnProviderID
        persisted.spawnModelID = spawnModelID
        persisted.spawnMode = spawnMode
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(persisted).write(to: persistenceURL, options: .atomic)
        } catch {
            // Losing layout state isn't worth interrupting the user for.
        }
    }

    // MARK: - Helpers

    private func run(_ failure: String, _ operation: @escaping @MainActor (AppStore) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(self)
            } catch {
                self.toast(.init(kind: .error, text: "\(failure): \(error.localizedDescription)"))
            }
        }
    }
}
