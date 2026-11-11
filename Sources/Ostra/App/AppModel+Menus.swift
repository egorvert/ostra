import AppKit
import OstraCore
import SwiftUI

/// A list of actions, each reachable with one key.
///
/// Menus show their keys, so nobody has to memorize a shortcut before using it.
struct KeyMenu {
    struct Item: Identifiable {
        var id: String
        var key: KeyCode
        var title: String
        var detail: String?
        var symbol: String?
        var isChecked = false
        var isEnabled = true
        var opensSubmenu = false
        var isDestructive = false
        var action: () -> Void
    }

    var title: String
    /// The menu to return to when the user backs out.
    var parent: MenuID?
    var items: [Item]
    /// A note under the items, such as a hint about what's missing.
    var footer: String?
}

extension AppModel {
    func menu(for id: MenuID) -> KeyMenu {
        switch id {
        case .main: mainMenu
        case .add: addMenu
        case .projects: projectsMenu
        case .models: modelsMenu
        case .permissions: permissionsMenu
        case .archived: archivedMenu
        }
    }

    private func item(
        _ key: Character,
        _ title: String,
        detail: String? = nil,
        symbol: String? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        submenu: Bool = false,
        _ action: @escaping () -> Void
    ) -> KeyMenu.Item {
        KeyMenu.Item(
            id: "\(key)-\(title)",
            key: .character(key),
            title: title,
            detail: detail,
            symbol: symbol,
            isChecked: checked,
            isEnabled: enabled,
            opensSubmenu: submenu,
            action: action
        )
    }

    /// The menu from the wireframe: a few destinations, each one key away.
    private var mainMenu: KeyMenu {
        var items = [
            item("k", "Search everything", detail: "⌘K") { [self] in open(.search, animated: false) },
            item("a", "See agents") { [self] in open(.picker, animated: false) },
            item("s", "Status pane", checked: statusPaneOpen) { [self] in
                closeOverlay()
                toggleStatusPane()
            },
            item("n", "New") { [self] in open(.menu(.add), animated: false) },
            item("w", "Other shortcuts") { [self] in open(.shortcuts, animated: true) },
            item(",", "Settings") { [self] in open(.settings, animated: true) },
        ]
        // Shown only while there's something to restore.
        if !store.archivedAgents.isEmpty {
            items.insert(
                item("r", "Restore archived", detail: "\(store.archivedAgents.count)") { [self] in
                    open(.menu(.archived), animated: false)
                },
                at: 4
            )
        }
        return KeyMenu(title: "Menu", parent: nil, items: items)
    }

    private var addMenu: KeyMenu {
        let project = store.currentProject
        let provider = store.spawnProvider
        let model = store.spawnModel
        return KeyMenu(
            title: "Add",
            parent: nil,
            items: [
                item("a", "Agent", detail: project?.title, enabled: project != nil && provider != nil) { [self] in
                    beginNewAgent()
                },
                item("p", "Project", detail: store.projects.isEmpty ? nil : "\(store.projects.count)") { [self] in
                    if store.projects.isEmpty {
                        addProjectFromPanel()
                    } else {
                        open(.menu(.projects), animated: false)
                    }
                },
                item("m", "Model", detail: model?.name, enabled: store.providers.contains(where: \.isReady)) { [self] in
                    open(.menu(.models), animated: false)
                },
                item("r", "Permissions", detail: store.spawnMode.label) { [self] in
                    open(.menu(.permissions), animated: false)
                },
            ],
            footer: project == nil
                ? "Add a project to give agents a place to work."
                : (provider == nil ? "No provider is ready. Sign in to Codex or Claude." : nil)
        )
    }

    private var projectsMenu: KeyMenu {
        var items: [KeyMenu.Item] = []
        for (index, project) in store.projects.prefix(9).enumerated() {
            let key = Character(String(index + 1))
            items.append(item(
                key,
                project.title,
                detail: "\(store.agents(in: project.id).count)",
                symbol: "folder",
                checked: project.id == store.currentProject?.id
            ) { [self] in
                store.currentProjectID = project.id
                closeOverlay()
            })
        }
        items.append(item("n", "New folder…") { [self] in addProjectFromPanel() })
        return KeyMenu(title: "Project for new agents", parent: .add, items: items)
    }

    private var modelsMenu: KeyMenu {
        var items: [KeyMenu.Item] = []
        let keys = Array("123456789abcdefghijklnopqrstuvwxyz")
        var next = 0
        let currentProvider = store.spawnProvider?.id
        let currentModel = store.spawnModel?.id
        for provider in store.providers where provider.isReady {
            for model in provider.models.prefix(8) {
                guard next < keys.count else { break }
                items.append(item(
                    keys[next],
                    model.name,
                    detail: provider.name,
                    checked: provider.id == currentProvider && model.id == currentModel
                ) { [self] in
                    store.spawnProviderID = provider.id
                    store.spawnModelID = model.id
                    open(.menu(.add), animated: false)
                })
                next += 1
            }
        }
        let unavailable = store.providers.filter { !$0.isReady && $0.statusMessage != nil }
        return KeyMenu(
            title: "Model",
            parent: .add,
            items: items,
            footer: items.isEmpty ? unavailable.first?.statusMessage ?? "No provider is ready." : nil
        )
    }

    private var permissionsMenu: KeyMenu {
        let details: [RuntimeMode: String] = [
            .approvalRequired: "Asks before commands and edits",
            .autoAcceptEdits: "Edits apply; commands ask",
            .auto: "Asks only for risky actions",
            .fullAccess: "Never asks",
        ]
        let items = RuntimeMode.allCases.enumerated().map { index, mode in
            item(
                Character(String(index + 1)),
                mode.label,
                detail: details[mode],
                checked: store.spawnMode == mode
            ) { [self] in
                store.spawnMode = mode
                open(.menu(.add), animated: false)
            }
        }
        return KeyMenu(title: "Permissions for new agents", parent: .add, items: items)
    }

    private var archivedMenu: KeyMenu {
        let archived = store.archivedAgents.sorted { $0.updatedAt > $1.updatedAt }.prefix(9)
        let items = archived.enumerated().map { index, snapshot in
            item(
                Character(String(index + 1)),
                snapshot.title,
                detail: store.project(snapshot.projectID)?.title,
                symbol: "arrow.uturn.backward"
            ) { [self] in
                store.restore(snapshot.id)
                closeOverlay()
            }
        }
        return KeyMenu(title: "Restore archived", parent: .main, items: Array(items))
    }
}

/// Every shortcut, grouped for the shortcuts sheet.
enum ShortcutCatalog {
    struct Entry: Identifiable {
        var keys: [String]
        var title: String
        var id: String { keys.joined() + title }
    }

    struct Section: Identifiable {
        var title: String
        var note: String?
        var entries: [Entry]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Modes", note: "Single keys work while the chat box doesn't have focus.", entries: [
            Entry(keys: ["↩"], title: "Type in the chat box"),
            Entry(keys: ["esc"], title: "Leave the chat box, close a panel"),
            Entry(keys: ["space"], title: "Open or close the chat"),
        ]),
        Section(title: "Primitives", entries: [
            Entry(keys: ["A"], title: "Add an agent or a project"),
            Entry(keys: ["S"], title: "Select an agent by name"),
            Entry(keys: ["D"], title: "Archive the agent (Z undoes it)"),
            Entry(keys: ["R"], title: "Rename the agent"),
            Entry(keys: ["⇧", "D"], title: "Delete the agent for good"),
            Entry(keys: ["M"], title: "Open the menu"),
            Entry(keys: ["C"], title: "Open the left panel"),
        ]),
        Section(title: "Agents", entries: [
            Entry(keys: ["⇥"], title: "Next agent (⇧⇥ for previous)"),
            Entry(keys: ["⌃", "⇥"], title: "Next agent, even while typing"),
            Entry(keys: ["F"], title: "Change what Tab visits"),
            Entry(keys: ["←", "↓", "↑", "→"], title: "Nearest agent"),
            Entry(keys: ["Y"], title: "Approve (⇧Y for always)"),
            Entry(keys: ["N"], title: "Deny"),
            Entry(keys: ["1", "–", "9"], title: "Pick an answer to a question"),
            Entry(keys: ["X"], title: "Stop the agent"),
        ]),
        Section(title: "Chat", entries: [
            Entry(keys: ["↩"], title: "Send (⇧↩ for a new line)"),
            Entry(keys: ["⌘", "⇧", "↩"], title: "Queue behind the current run"),
            Entry(keys: ["1", "2", "3"], title: "Chat, activity, diff"),
            Entry(keys: ["[", "]"], title: "Previous and next view"),
            Entry(keys: ["⌘", "V"], title: "Paste text, images, or files"),
            Entry(keys: ["⌘", "U"], title: "Attach files"),
            Entry(keys: ["\\"], title: "Split the chat in two"),
            Entry(keys: ["|"], title: "Swap the two sides"),
            Entry(keys: ["⌘", "↩"], title: "Approve while typing"),
            Entry(keys: ["⌃", "C"], title: "Stop the agent while typing"),
        ]),
        Section(title: "Canvas", entries: [
            Entry(keys: ["0"], title: "Zoom to fit"),
            Entry(keys: ["+"], title: "Zoom in"),
            Entry(keys: ["-"], title: "Zoom out"),
            Entry(keys: ["G"], title: "Go to the selected agent"),
            Entry(keys: ["T"], title: "Toggle the status pane"),
        ]),
        Section(title: "Left panel", entries: [
            Entry(keys: ["C"], title: "Open or close the panel"),
            Entry(keys: ["⌘", "1"], title: "Diff"),
            Entry(keys: ["⌘", "2"], title: "Files"),
            Entry(keys: ["⌘", "3"], title: "Terminal (⇧esc to leave it)"),
            Entry(keys: ["⌘", "4"], title: "Activity"),
            Entry(keys: ["1", "–", "4"], title: "The same, with the chat closed"),
        ]),
        Section(title: "Anywhere", entries: [
            Entry(keys: ["⌘", "K"], title: "Search everything"),
            Entry(keys: ["⌘", "N"], title: "New agent"),
            Entry(keys: ["⌘", ","], title: "Settings"),
            Entry(keys: ["⌘", "."], title: "Stop the agent"),
        ]),
    ]
}
