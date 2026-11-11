import AppKit
import Observation
import OstraCore
import SwiftUI

enum ChatTab: String, CaseIterable, Identifiable {
    case chat
    case activity
    case diff

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "Chat"
        case .activity: "Activity"
        case .diff: "Diff"
        }
    }
}

enum WorkspaceTool: String, CaseIterable, Identifiable {
    case diff
    case files
    case terminal
    case activity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .diff: "Diff"
        case .files: "Files"
        case .terminal: "Terminal"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .diff: "plusminus"
        case .files: "folder"
        case .terminal: "terminal"
        case .activity: "waveform.path.ecg"
        }
    }
}

enum MenuID: Hashable {
    case main
    case add
    case projects
    case models
    case permissions
    case archived
}

/// What floats above the HUD and takes the keyboard first.
enum Overlay: Equatable {
    case none
    case menu(MenuID)
    case picker
    case confirmDelete(AgentID)
    case settings
    case shortcuts
}

/// UI state and behavior that sits between the store and the views:
/// which panels are open, where the camera looks, and what each key does.
@Observable
final class AppModel {
    let store: AppStore
    let settings: AppSettings
    let focus = FocusCoordinator()
    let hudRegions = HUDRegions()

    // MARK: Panels

    var chatOpen = false
    var chatTab: ChatTab = .chat
    var workspaceOpen = false
    var workspaceTool: WorkspaceTool = .diff
    var workspaceWidth: CGFloat = 560
    var statusPaneOpen = false

    // MARK: Overlays

    /// A short message at the top of the window that fades on its own.
    var hint: String?
    var overlay: Overlay = .none
    var menuHighlight = 0
    var pickerQuery = ""
    var pickerHighlight = 0

    // MARK: Input

    /// True while the chat box has the keyboard.
    var isTyping = false
    /// Unsent text, per agent. The empty key holds the draft for a new agent.
    var drafts: [String: String] = [:]
    /// Text for the diff panes, per agent.
    var diffs: [AgentID: DiffState] = [:]
    /// The height each agent's conversation needs, so the pane can hug short ones.
    var conversationHeights: [AgentID: CGFloat] = [:]

    // MARK: Canvas

    var viewSize: CGSize = .zero
    /// The agent being dragged, so its card can lift.
    var draggingAgentID: AgentID?

    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var scrollMonitor: Any?
    @ObservationIgnored var reduceMotion = false

    init(store: AppStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        store.start()
        installMonitors()
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let press = KeyPress(event: event) else { return event }
            return self.handle(press, event: event) ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.handleCanvasGesture(event) ? nil : event
        }
    }

    // MARK: - Selection

    /// Selects an agent and brings its card into view.
    func select(_ id: AgentID?, openChat: Bool = false, animated: Bool = true) {
        store.select(id)
        if id == nil {
            chatOpen = false
        } else if openChat {
            chatOpen = true
        }
        if let agent = store.agent(id) {
            reveal(agent, animated: animated)
        }
    }

    func cycle(forward: Bool) {
        guard let agent = store.cycle(forward: forward) else {
            if store.cycleFilter != .all {
                flash("Nothing in “\(store.cycleFilter.label.lowercased())”. Press F to change the filter.")
            }
            return
        }
        reveal(agent, animated: true)
    }

    func selectNeighbor(_ direction: CGVector) {
        if let agent = store.selectNeighbor(direction) {
            reveal(agent, animated: true)
        }
    }

    /// Steps the cycle filter and says what Tab visits now.
    func nextFilter() {
        store.cycleFilter = store.cycleFilter.next
        let count = store.cycleCandidates.count
        flash("Tab cycles: \(store.cycleFilter.label.lowercased()) · \(count)")
    }

    /// Shows a hint for a moment.
    func flash(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }

    /// The canvas background was clicked.
    func canvasTapped() {
        closeOverlay()
        focus.blur()
        if chatOpen {
            chatOpen = false
        } else {
            store.select(nil)
        }
    }

    // MARK: - Chat

    var draftKey: String { store.selectedAgentID?.rawValue ?? "" }

    var draft: String {
        get { drafts[draftKey] ?? "" }
        set { drafts[draftKey] = newValue }
    }

    /// Sends the draft: to the selected agent, or as the first prompt of a new agent.
    func submitDraft(queue: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = store.selectedAgentID {
            store.send(text, to: id, queue: queue)
            chatOpen = true
        } else {
            guard store.currentProject != nil else {
                store.toast(.init(kind: .error, text: "Add a project first: press A, then P."))
                return
            }
            store.spawn(prompt: text)
            chatOpen = true
        }
        draft = ""
    }

    func focusInput() {
        closeOverlay()
        if store.selectedAgentID != nil { chatOpen = true }
        focus.focusChat()
    }

    func toggleChat(animated: Bool) {
        guard store.selectedAgentID != nil else { return }
        Motion.perform(chatOpen ? Motion.panelOut : Motion.panel, animated: animated && !reduceMotion) {
            chatOpen.toggle()
        }
        if !chatOpen { focus.blur() }
    }

    func setChatTab(_ tab: ChatTab) {
        chatTab = tab
        if tab == .diff, let id = store.selectedAgentID { loadDiff(for: id) }
    }

    func toggleSplit() {
        if store.pinnedAgentID != nil {
            store.pin(nil)
            return
        }
        // Pin the current agent and move on to the next one.
        guard let current = store.selectedAgentID, store.agents.count > 1 else { return }
        if store.cycle(forward: true) != nil, store.selectedAgentID != current {
            store.pin(current)
            chatOpen = true
        }
    }

    // MARK: - Agent actions

    func archiveSelected() {
        guard let id = store.selectedAgentID else { return }
        store.archive(id)
        if store.selectedAgentID == nil { chatOpen = false }
    }

    func respond(_ decision: ApprovalDecision) {
        guard let agent = store.selectedAgent, agent.phase == .awaitingApproval else { return }
        store.respond(decision, to: agent.id)
    }

    /// Answers the selected agent's question with one of its choices.
    func chooseAnswer(_ index: Int) {
        guard let agent = store.selectedAgent, agent.phase == .awaitingInput,
              let request = agent.snapshot.pendingRequest, let question = request.questions.first,
              question.choices.indices.contains(index) else { return }
        store.answer(request: request.id, of: agent.id, answers: [question.id: question.choices[index].label])
    }

    func addProjectFromPanel() {
        closeOverlay()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Project"
        panel.message = "Choose a folder for agents to work in."
        if panel.runModal() == .OK, let url = panel.url {
            store.addProject(path: url.path)
        }
    }

    /// Prepares the chat box to spawn an agent.
    func beginNewAgent() {
        closeOverlay()
        store.select(nil)
        chatOpen = false
        focus.focusChat()
    }

    // MARK: - Workspace panel

    func toggleWorkspace(animated: Bool) {
        Motion.perform(workspaceOpen ? Motion.panelOut : Motion.panel, animated: animated && !reduceMotion) {
            workspaceOpen.toggle()
        }
        if workspaceOpen, workspaceTool == .diff, let id = store.selectedAgentID {
            loadDiff(for: id)
        }
    }

    func setWorkspaceTool(_ tool: WorkspaceTool) {
        workspaceTool = tool
        if !workspaceOpen { toggleWorkspace(animated: false) }
        if tool == .diff, let id = store.selectedAgentID { loadDiff(for: id) }
    }

    // MARK: - Diffs

    struct DiffState: Equatable {
        var files: [FileDiff] = []
        var isLoading = false
        var error: String?
        var loadedAt: Date?
    }

    func loadDiff(for id: AgentID) {
        var state = diffs[id] ?? DiffState()
        guard !state.isLoading else { return }
        state.isLoading = true
        state.error = nil
        diffs[id] = state
        let backend = store.backend
        Task {
            var next = diffs[id] ?? DiffState()
            do {
                let text = try await backend.diff(for: id)
                let files = await Task.detached { UnifiedDiff.parse(text) }.value
                next.files = files
                next.error = nil
            } catch {
                next.error = error.localizedDescription
            }
            next.isLoading = false
            next.loadedAt = .now
            diffs[id] = next
        }
    }

    // MARK: - Overlays

    func open(_ overlay: Overlay, animated: Bool) {
        Motion.perform(Motion.popIn, animated: animated && !reduceMotion) {
            menuHighlight = 0
            pickerHighlight = 0
            pickerQuery = ""
            self.overlay = overlay
        }
    }

    func closeOverlay(animated: Bool = false) {
        guard overlay != .none else { return }
        Motion.perform(Motion.popOut, animated: animated && !reduceMotion) {
            overlay = .none
        }
    }

    func toggleMenu(_ id: MenuID, animated: Bool) {
        if overlay == .menu(id) {
            closeOverlay(animated: animated)
        } else {
            open(.menu(id), animated: animated)
        }
    }
}

/// Moves keyboard focus between the chat box and the canvas.
final class FocusCoordinator {
    weak var chatInput: NSTextView?

    func focusChat() {
        // The text view may not exist yet when a panel is still mounting.
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.chatInput, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    func blur() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        window.makeFirstResponder(nil)
    }

    /// The view that has the keyboard, if any.
    var firstResponder: NSResponder? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
    }

    /// True while a text field or text view takes typing.
    var isEditingText: Bool {
        firstResponder is NSTextView
    }
}

/// The screen areas that HUD panels cover.
///
/// The scroll and pinch monitor consults them: gestures over a panel belong to
/// the panel, and gestures anywhere else move the canvas.
final class HUDRegions {
    private var frames: [String: CGRect] = [:]

    func set(_ id: String, _ frame: CGRect?) {
        frames[id] = frame
    }

    func contains(_ point: CGPoint) -> Bool {
        frames.values.contains { $0.contains(point) }
    }

    func frame(_ id: String) -> CGRect? { frames[id] }
}

extension View {
    /// Marks the view as a HUD panel that owns the scroll gestures over it.
    func hudRegion(_ id: String, in regions: HUDRegions) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            regions.set(id, frame)
        }
        .onDisappear { regions.set(id, nil) }
    }
}
