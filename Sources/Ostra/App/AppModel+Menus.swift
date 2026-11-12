import AppKit
import OstraCore
import SwiftUI

/// A list of actions, each reachable with one key.
///
/// Menus show their keys, so nobody has to memorize a shortcut before using
/// it. A row that runs a command shows the command's own key, which does the
/// same thing with the menu closed. Choices in a list take numbers.
struct KeyMenu {
    struct Item: Identifiable {
        var id: String
        /// The keycap: a command's key, or a choice's number.
        var key: String?
        /// The number key that picks a choice. Command rows have none: their
        /// key runs the command whether the menu is open or not.
        var choice: KeyChord?
        var title: String
        var detail: String?
        var symbol: String?
        var isChecked = false
        var isEnabled = true
        var opensSubmenu = false
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
        case .projects: projectsMenu
        case .archived: archivedMenu
        }
    }

    /// A row that runs a command and shows the command's key.
    private func item(
        _ command: Command,
        _ title: String,
        detail: String? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        submenu: Bool = false
    ) -> KeyMenu.Item {
        KeyMenu.Item(
            id: command.rawValue,
            key: keymap.label(for: command),
            title: title,
            detail: detail,
            isChecked: checked,
            isEnabled: enabled,
            opensSubmenu: submenu
        ) { [self] in
            _ = perform(command)
        }
    }

    /// A numbered choice in a list.
    private func choice(
        _ number: Int,
        _ title: String,
        detail: String? = nil,
        symbol: String? = nil,
        checked: Bool = false,
        _ action: @escaping () -> Void
    ) -> KeyMenu.Item {
        let digit = Character(String(number))
        return KeyMenu.Item(
            id: "\(number)-\(title)",
            key: String(digit),
            choice: .key(digit),
            title: title,
            detail: detail,
            symbol: symbol,
            isChecked: checked,
            action: action
        )
    }

    /// A few destinations, each one key away.
    private var mainMenu: KeyMenu {
        let project = store.currentProject
        var items = [
            item(.search, "Search everything"),
            item(.selectAgent, "Select an agent"),
            item(.newAgent, "New agent", detail: project?.title, enabled: project != nil && store.spawnProvider != nil),
            item(.projects, "Projects", detail: store.projects.isEmpty ? nil : "\(store.projects.count)", submenu: !store.projects.isEmpty),
            item(.statusPane, "Status pane", checked: statusPaneOpen),
            item(.shortcuts, "Shortcuts"),
            item(.settings, "Settings"),
        ]
        // Shown only while there's something to restore.
        if !store.archivedAgents.isEmpty {
            items.insert(
                item(.restoreArchived, "Restore archived", detail: "\(store.archivedAgents.count)", submenu: true),
                at: 5
            )
        }
        return KeyMenu(
            title: "Menu",
            parent: nil,
            items: items,
            footer: project == nil ? "Add a project to give agents a place to work." : nil
        )
    }

    private var projectsMenu: KeyMenu {
        var items: [KeyMenu.Item] = []
        for (index, project) in store.projects.prefix(9).enumerated() {
            items.append(choice(
                index + 1,
                project.title,
                detail: "\(store.agents(in: project.id).count)",
                symbol: "folder",
                checked: project.id == store.currentProject?.id
            ) { [self] in
                store.currentProjectID = project.id
            })
        }
        items.append(item(.addProject, "Add a folder…"))
        return KeyMenu(title: "Project for new agents", parent: .main, items: items)
    }

    private var archivedMenu: KeyMenu {
        let archived = store.archivedAgents.sorted { $0.updatedAt > $1.updatedAt }.prefix(9)
        let items = archived.enumerated().map { index, snapshot in
            choice(
                index + 1,
                snapshot.title,
                detail: store.project(snapshot.projectID)?.title,
                symbol: "arrow.uturn.backward"
            ) { [self] in
                store.restore(snapshot.id)
            }
        }
        return KeyMenu(title: "Restore archived", parent: .main, items: Array(items))
    }
}
