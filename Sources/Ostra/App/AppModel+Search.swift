import AppKit
import OstraCore
import SwiftUI

/// One thing global search can find.
struct SearchResult: Identifiable {
    enum Section: String, CaseIterable {
        case agents = "Agents"
        case actions = "Actions"
        case projects = "Projects"
        case files = "Files"
        case messages = "Messages"
        case archived = "Archived"

        /// The most results a section shows, so one kind never buries the rest.
        var limit: Int {
            switch self {
            case .agents: 6
            case .actions: 7
            case .projects: 4
            case .files: 8
            case .messages: 8
            case .archived: 4
            }
        }
    }

    var id: String
    var section: Section
    var title: String
    var subtitle: String?
    /// An SF Symbol for the row. Agents show their status dot instead.
    var symbol: String = "circle"
    var agentID: AgentID?
    /// The keys that do the same thing without search.
    var keys: [String] = []
    var score = 0
    var run: () -> Void
}

/// A file that matches the search text.
struct FileMatch: Hashable, Sendable {
    var root: String
    var relativePath: String
    var score: Int
}

/// Global search: one field that finds agents, actions, projects, files,
/// messages, and archived agents.
extension AppModel {
    func toggleSearch() {
        if overlay == .search {
            closeOverlay()
        } else {
            open(.search, animated: false)
        }
    }

    /// Gets everything search needs ready: every conversation, and the file lists.
    func prepareSearch() {
        store.loadsEveryConversation = true
        let roots = store.projects.map(\.path)
        Task {
            await FileIndex.shared.refresh(roots: roots)
            refreshFileMatches()
        }
    }

    /// The results for the search text, grouped by section, best first.
    var searchSections: [(section: SearchResult.Section, results: [SearchResult])] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        var all: [SearchResult] = []
        all += agentResults(query)
        all += actionResults(query)
        all += projectResults(query)
        all += archivedResults(query)
        if !query.isEmpty {
            all += fileResults()
            all += messageResults(query)
        }

        var sections: [(SearchResult.Section, [SearchResult])] = []
        for section in SearchResult.Section.allCases {
            let results = all.filter { $0.section == section }
                .sorted { $0.score > $1.score }
                .prefix(section.limit)
            if !results.isEmpty { sections.append((section, Array(results))) }
        }
        // With text, the section with the best match leads.
        if !query.isEmpty {
            sections.sort { ($0.1.first?.score ?? 0) > ($1.1.first?.score ?? 0) }
        }
        return sections.map { (section: $0.0, results: $0.1) }
    }

    /// Every result in the order the list shows them.
    var searchResults: [SearchResult] {
        searchSections.flatMap(\.results)
    }

    func runSearchResult(_ result: SearchResult) {
        closeOverlay()
        focus.blur()
        result.run()
    }

    // MARK: - Sources

    private func agentResults(_ query: String) -> [SearchResult] {
        store.canvasOrder.compactMap { agent in
            let project = store.project(agent.projectID)?.title ?? ""
            let score: Int?
            if query.isEmpty {
                // Agents that want the user come first.
                score = agent.needsAttention ? 2 : (agent.phase.isRunning ? 1 : 0)
            } else {
                score = [
                    Fuzzy.score(query, in: agent.name).map { $0 + 400 },
                    Fuzzy.score(query, in: agent.title).map { $0 + 100 },
                    Fuzzy.score(query, in: project),
                    Fuzzy.score(query, in: agent.phase.label),
                ].compactMap { $0 }.max()
            }
            guard let score else { return nil }
            return SearchResult(
                id: "agent-\(agent.id.rawValue)",
                section: .agents,
                title: agent.name,
                subtitle: agent.phase.isActive || agent.phase == .failed ? agent.liveLine : agent.title,
                agentID: agent.id,
                score: score
            ) { [self] in
                select(agent.id, openChat: true)
            }
        }
    }

    private func projectResults(_ query: String) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        return store.projects.compactMap { project in
            guard let score = [Fuzzy.score(query, in: project.title), Fuzzy.score(query, in: project.path).map { $0 - 200 }]
                .compactMap({ $0 }).max() else { return nil }
            let count = store.agents(in: project.id).count
            return SearchResult(
                id: "project-\(project.id.rawValue)",
                section: .projects,
                title: project.title,
                subtitle: count == 1 ? "1 agent" : "\(count) agents",
                symbol: "folder",
                score: score
            ) { [self] in
                store.currentProjectID = project.id
                frame(store.groupFrame(for: project.id), animated: true)
            }
        }
    }

    private func archivedResults(_ query: String) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        return store.archivedAgents.compactMap { snapshot in
            guard let score = Fuzzy.score(query, in: snapshot.title) else { return nil }
            return SearchResult(
                id: "archived-\(snapshot.id.rawValue)",
                section: .archived,
                title: snapshot.title,
                subtitle: "Restore to \(store.project(snapshot.projectID)?.title ?? "its project")",
                symbol: "arrow.uturn.backward",
                score: score - 150
            ) { [self] in
                store.restore(snapshot.id)
            }
        }
    }

    private func fileResults() -> [SearchResult] {
        searchFileMatches.map { match in
            let name = (match.relativePath as NSString).lastPathComponent
            let folder = (match.relativePath as NSString).deletingLastPathComponent
            let project = store.projects.first { $0.path == match.root }?.title ?? (match.root as NSString).lastPathComponent
            return SearchResult(
                id: "file-\(match.root)/\(match.relativePath)",
                section: .files,
                title: name,
                subtitle: folder.isEmpty ? project : "\(project)/\(folder)",
                symbol: "doc",
                score: match.score - 120
            ) { [self] in
                showFile(match.root + "/" + match.relativePath, root: match.root)
            }
        }
    }

    /// Messages and commands that contain the search text.
    private func messageResults(_ query: String) -> [SearchResult] {
        guard query.count >= 2 else { return [] }
        var results: [SearchResult] = []
        for agent in store.agents {
            // Newest first, and a few per agent, so one long thread doesn't fill the list.
            var found = 0
            for row in ChatRow.rows(from: agent.conversation.items).reversed() {
                guard found < 3 else { break }
                let (text, who): (String, String)
                switch row {
                case let .user(_, body, _): (text, who) = (body, "You")
                case let .assistant(_, body, _): (text, who) = (body, agent.name)
                case let .work(_, items):
                    let commands = items.compactMap { item -> String? in
                        if case let .command(call) = item.content { return call.command }
                        return nil
                    }
                    (text, who) = (commands.joined(separator: "\n"), "Command")
                default: continue
                }
                guard let snippet = Fuzzy.snippet(of: text, around: query) else { continue }
                found += 1
                let rowID = row.id
                results.append(SearchResult(
                    id: "message-\(agent.id.rawValue)-\(rowID)",
                    section: .messages,
                    title: snippet,
                    subtitle: who == agent.name ? agent.name : "\(who) · \(agent.name)",
                    symbol: who == "Command" ? "terminal" : "text.bubble",
                    score: 380 - results.count
                ) { [self] in
                    select(agent.id, openChat: true)
                    Motion.instantly { setChatTab(.chat) }
                    scrollTargets[agent.id] = rowID
                })
            }
        }
        return results
    }

    /// Opens the Files tool on one file.
    func showFile(_ path: String, root: String) {
        fileSelection[root] = path
        if store.currentProject?.path != root, store.selectedAgent?.snapshot.workingDirectory != root,
           let project = store.projects.first(where: { $0.path == root }) {
            // The Files tool follows the selection, so point it at the file's project.
            store.select(nil)
            store.currentProjectID = project.id
        }
        Motion.perform(Motion.tabContent) { setWorkspaceTool(.files) }
    }

    /// Looks for files that match the search text, off the main thread.
    func refreshFileMatches() {
        fileMatchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            searchFileMatches = []
            return
        }
        fileMatchTask = Task { [weak self] in
            let matches = await FileIndex.shared.matches(for: query, limit: SearchResult.Section.files.limit)
            guard !Task.isCancelled else { return }
            self?.searchFileMatches = matches
        }
    }

    // MARK: - Actions

    /// Everything the app can do, as search results. A result with an empty
    /// query shows only when it's in `featured`.
    private func actionResults(_ query: String) -> [SearchResult] {
        let actions = allActions
        if query.isEmpty {
            return actions.filter(\.featured).enumerated().map { index, action in
                action.result(score: 100 - index, model: self)
            }
        }
        return actions.compactMap { action in
            let scores = [Fuzzy.score(query, in: action.title)] + action.keywords.map { Fuzzy.score(query, in: $0).map { $0 - 150 } }
            guard let score = scores.compactMap({ $0 }).max() else { return nil }
            return action.result(score: score, model: self)
        }
    }

    struct Action {
        var id: String
        var title: String
        var subtitle: String?
        var symbol: String
        var keys: [String] = []
        var keywords: [String] = []
        var featured = false
        var run: () -> Void

        func result(score: Int, model: AppModel) -> SearchResult {
            SearchResult(
                id: "action-\(id)",
                section: .actions,
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                keys: keys,
                score: score,
                run: run
            )
        }
    }

    /// The keycap for a command, as the keymap has it now.
    private func keys(_ command: Command) -> [String] {
        keymap.label(for: command).map { [$0] } ?? []
    }

    private var allActions: [Action] {
        let selected = store.selectedAgent
        var actions: [Action] = [
            Action(id: "new-agent", title: "New agent", subtitle: store.currentProject.map { "In \($0.title)" },
                   symbol: "plus", keys: keys(.newAgent), keywords: ["add", "spawn", "create", "start"], featured: true) { [self] in
                beginNewAgent()
            },
            Action(id: "add-project", title: "Add a project folder", symbol: "folder.badge.plus", keys: keys(.addProject),
                   keywords: ["open", "repository", "directory"], featured: true) { [self] in
                addProjectFromPanel()
            },
            Action(id: "attach", title: "Attach files or images", symbol: "paperclip", keys: keys(.attachFiles),
                   keywords: ["upload", "image", "screenshot", "file"]) { [self] in
                chooseAttachments()
            },
            Action(id: "paste", title: "Paste from the clipboard", symbol: "doc.on.clipboard", keys: ["⌘V"],
                   keywords: ["image", "screenshot"]) { [self] in
                pasteIntoDraft()
            },
            Action(id: "workspace", title: workspaceOpen ? "Close the code panel" : "Open the code panel",
                   symbol: settings.data.codePanelSide == .left ? "sidebar.left" : "sidebar.right", keys: keys(.codePanel), keywords: ["workspace", "tools", "sidebar"], featured: true) { [self] in
                toggleWorkspace()
            },
            Action(id: "status", title: statusPaneOpen ? "Hide the status pane" : "Show the status pane",
                   symbol: "list.bullet", keys: keys(.statusPane), keywords: ["agents", "list", "overview"]) { [self] in
                toggleStatusPane()
            },
            Action(id: "fit", title: "Zoom to fit", symbol: "arrow.up.left.and.arrow.down.right", keys: keys(.zoomToFit),
                   keywords: ["canvas", "camera", "everything", "reset"], featured: true) { [self] in
                zoomToFit(animated: true)
            },
            Action(id: "zoom-in", title: "Zoom in", symbol: "plus.magnifyingglass", keys: keys(.zoomIn), keywords: ["canvas"]) { [self] in
                zoomStep(1.25)
            },
            Action(id: "zoom-out", title: "Zoom out", symbol: "minus.magnifyingglass", keys: keys(.zoomOut), keywords: ["canvas"]) { [self] in
                zoomStep(0.8)
            },
            Action(id: "settings", title: "Settings", symbol: "gearshape", keys: keys(.settings),
                   keywords: ["preferences", "background", "glass", "appearance", "theme"], featured: true) { [self] in
                open(.settings, animated: true)
            },
            Action(id: "shortcuts", title: "Keyboard shortcuts", symbol: "keyboard", keys: keys(.shortcuts),
                   keywords: ["keys", "help", "cheat sheet"], featured: true) { [self] in
                open(.shortcuts, animated: true)
            },
            Action(id: "filter", title: "Change what Tab cycles through", subtitle: store.cycleFilter.label,
                   symbol: "line.3.horizontal.decrease", keys: keys(.cycleFilter), keywords: ["filter", "needs attention", "running"]) { [self] in
                nextFilter()
            },
            Action(id: "quit", title: "Quit Ostra", symbol: "power", keys: ["⌘Q"], keywords: ["exit", "close"]) {
                Runtime.quit()
            },
        ]

        for (index, tool) in WorkspaceTool.allCases.enumerated() {
            actions.append(Action(
                id: "tool-\(tool.rawValue)", title: "Show \(tool.label.lowercased())", subtitle: "Code panel",
                symbol: tool.symbol, keys: ["⌥⌘\(index + 1)"], keywords: ["workspace", "panel", tool.label]
            ) { [self] in
                Motion.perform(Motion.tabContent) { setWorkspaceTool(tool) }
            })
        }

        for mode in AppearanceMode.allCases {
            actions.append(Action(
                id: "appearance-\(mode.rawValue)", title: "Appearance: \(mode.label)", symbol: "circle.lefthalf.filled",
                keywords: ["theme", "dark mode", "light mode"]
            ) { [self] in
                settings.data.appearance = mode
            })
        }
        for style in CanvasStyle.allCases where style != .image || settings.data.backgroundImagePath != nil {
            actions.append(Action(
                id: "canvas-\(style.rawValue)", title: "Background: \(style.label)", symbol: "square.grid.3x3",
                keywords: ["canvas", "wallpaper"]
            ) { [self] in
                settings.data.canvasStyle = style
            })
        }

        for provider in store.providers where provider.isReady {
            for model in provider.models {
                actions.append(Action(
                    id: "model-\(provider.id)-\(model.id)", title: "Use \(model.name) for new agents",
                    subtitle: provider.name, symbol: "cpu", keywords: ["model", provider.name]
                ) { [self] in
                    store.spawnProviderID = provider.id
                    store.spawnModelID = model.id
                })
            }
        }
        for mode in RuntimeMode.allCases {
            actions.append(Action(
                id: "mode-\(mode.rawValue)", title: "New agents: \(mode.label.lowercased())",
                subtitle: "Permissions", symbol: "lock.shield", keywords: ["permissions", "approval", "access"]
            ) { [self] in
                store.spawnMode = mode
            })
        }

        if let selected {
            let name = selected.name
            actions += [
                Action(id: "rename", title: "Rename \(name)", symbol: "pencil", keys: keys(.rename), keywords: ["name", "edit"]) { [self] in
                    beginRename(selected.id)
                },
                Action(id: "chat", title: chatOpen ? "Close the chat" : "Open the chat", subtitle: name,
                       symbol: "bubble.left", keys: keys(.toggleChat), keywords: ["conversation", "messages"]) { [self] in
                    toggleChat()
                },
                Action(id: "center", title: "Go to \(name) on the canvas", symbol: "scope", keys: keys(.goToAgent),
                       keywords: ["center", "find", "camera"]) { [self] in
                    center(on: selected, animated: true)
                },
                Action(id: "archive", title: "Archive \(name)", symbol: "archivebox", keys: keys(.archive), keywords: ["remove", "hide"]) { [self] in
                    archive(selected.id)
                },
                Action(id: "delete", title: "Delete \(name)", symbol: "trash", keys: keys(.delete), keywords: ["remove"]) { [self] in
                    open(.confirmDelete(selected.id), animated: true)
                },
            ]
            for (index, tab) in ChatTab.allCases.enumerated() {
                actions.append(Action(
                    id: "tab-\(tab.rawValue)", title: "Show \(name)’s \(tab.label.lowercased())", subtitle: "Chat pane",
                    symbol: "rectangle.split.3x1", keys: ["⌘\(index + 1)"], keywords: [tab.label]
                ) { [self] in
                    openChat()
                    Motion.perform(Motion.tabContent) { setChatTab(tab) }
                })
            }
            if selected.phase.isActive {
                actions.append(Action(id: "stop", title: "Stop \(name)", symbol: "stop.fill", keys: keys(.stop),
                                      keywords: ["interrupt", "cancel"]) { [self] in
                    store.interrupt(selected.id)
                })
            }
            if store.agents.count > 1 {
                actions.append(Action(
                    id: "split", title: store.pinnedAgentID == nil ? "Split the chat" : "Close the split",
                    symbol: "rectangle.split.2x1", keys: keys(.split), keywords: ["side by side", "two", "pin"]
                ) { [self] in
                    toggleSplit()
                })
            }
        }
        return actions
    }

    // MARK: - Keys

    func handleSearchKey(_ press: KeyPress) -> Bool {
        let results = searchResults
        switch press.key {
        case .escape:
            closeOverlay()
            focus.blur()
        case .down:
            if !results.isEmpty { searchHighlight = (searchHighlight + 1) % results.count }
        case .up:
            if !results.isEmpty { searchHighlight = (searchHighlight - 1 + results.count) % results.count }
        case .tab:
            if !results.isEmpty {
                searchHighlight = (searchHighlight + (press.shift ? results.count - 1 : 1)) % results.count
            }
        case .character("n") where press.control:
            if !results.isEmpty { searchHighlight = (searchHighlight + 1) % results.count }
        case .character("p") where press.control:
            if !results.isEmpty { searchHighlight = (searchHighlight - 1 + results.count) % results.count }
        case .enter:
            if results.indices.contains(searchHighlight) {
                runSearchResult(results[searchHighlight])
            }
        default:
            // Everything else types into the search field.
            return false
        }
        return true
    }
}

/// The files in every project folder, listed once and searched many times.
actor FileIndex {
    static let shared = FileIndex()

    private var files: [String: [String]] = [:]
    private var listedAt: [String: Date] = [:]

    /// Folders that hold generated or vendored files, which nobody searches for.
    private static let skipped: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", "target",
        ".next", ".turbo", ".venv", "venv", "__pycache__", ".cache", ".swiftpm", ".idea",
    ]
    private static let cap = 40_000

    /// Lists the folders again when the last listing is older than a minute.
    func refresh(roots: [String]) {
        for root in roots {
            if let listed = listedAt[root], Date.now.timeIntervalSince(listed) < 60 { continue }
            files[root] = Self.list(root)
            listedAt[root] = .now
        }
        for root in files.keys where !roots.contains(root) {
            files[root] = nil
            listedAt[root] = nil
        }
    }

    func matches(for query: String, limit: Int) -> [FileMatch] {
        var matches: [FileMatch] = []
        for (root, paths) in files {
            for path in paths {
                if Task.isCancelled { return [] }
                let name = (path as NSString).lastPathComponent
                // A match in the file name beats one in its folders.
                let score = Fuzzy.score(query, in: name).map { $0 + 200 } ?? (query.contains("/") ? Fuzzy.score(query, in: path) : nil)
                if let score { matches.append(FileMatch(root: root, relativePath: path, score: score)) }
            }
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func list(_ root: String) -> [String] {
        let base = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var paths: [String] = []
        let prefix = base.path.hasSuffix("/") ? base.path.count : base.path.count + 1
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                // Hidden folders hold tooling, not the project's own files.
                if skipped.contains(name) || name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            paths.append(String(url.path.dropFirst(prefix)))
            if paths.count >= cap { break }
        }
        return paths
    }
}
