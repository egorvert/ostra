import AppKit
import OstraCore
import SwiftUI

/// Where the keyboard is, which decides the keys that run commands.
enum KeyMode {
    /// Nothing takes typing, so single keys are commands.
    case command
    /// The chat box has the keyboard. Chords with Command or Control run
    /// commands, and so does Tab.
    case typing
    /// The terminal has the keyboard. Only Command chords run commands, so
    /// Control and Tab reach the shell.
    case terminal
    /// A search field or a sheet has the keyboard. Only Command chords run commands.
    case field

    func allows(_ chord: KeyChord) -> Bool {
        switch self {
        case .command: true
        case .typing: chord.worksWhileTyping
        case .terminal, .field: chord.command
        }
    }
}

/// The keyboard model.
///
/// Ostra is modal. While the chat box has focus, keys type text and Esc
/// leaves. Otherwise single keys are commands: A adds an agent, S selects,
/// D archives, M opens the menu. A key means the same thing whether a menu
/// is open or not. Every command lives in `Keymap`, so the user can change
/// its keys from the shortcuts sheet.
extension AppModel {
    /// Routes a key press. Returns true when the press is consumed.
    func handle(_ press: KeyPress, event: NSEvent) -> Bool {
        // Sheets and open panels run their own keyboard.
        guard let window = event.window, window === NSApp.mainWindow, window.attachedSheet == nil else {
            return false
        }
        return route(press)
    }

    var keymap: Keymap { settings.keymap }

    /// A tooltip that ends with the command's key, such as "Menu (M)".
    func help(_ text: String, _ command: Command) -> String {
        keymap.label(for: command).map { "\(text) (\($0))" } ?? text
    }

    /// Applies the keymap to a press, whatever produced it.
    func route(_ press: KeyPress) -> Bool {
        if let slot = recordingShortcut {
            recordShortcut(press, into: slot)
            return true
        }

        // An open name editor takes every key but Esc. Return reaches the
        // field, which commits.
        if rename != nil {
            if press.key == .escape {
                cancelRename()
                return true
            }
            return false
        }

        switch overlay {
        case let .menu(id):
            return handleMenuKey(press, menu: id)
        case .picker:
            return handlePickerKey(press) || runCommands(press, in: .field)
        case .search:
            return handleSearchKey(press) || runCommands(press, in: .field)
        case let .confirmDelete(id):
            if press.key == .enter || press.isCharacter("y") {
                confirmDelete(id)
            } else if press.key == .escape || press.isCharacter("n") {
                closeOverlay(animated: true)
            } else {
                return runCommands(press, in: .field) || true
            }
            return true
        case .settings, .shortcuts:
            if press.key == .escape {
                closeOverlay(animated: true)
                return true
            }
            if runCommands(press, in: .field) { return true }
            // Let the panel's own controls take the rest.
            return focus.isEditingText ? false : press.key != .tab && press.key != .space
        case .none:
            break
        }

        if focus.isTerminalFocused {
            if press.key == .escape, press.shift {
                focus.blur()
                return true
            }
            return runCommands(press, in: .terminal)
        }

        if focus.isEditingText {
            if press.key == .escape {
                focus.blur()
                return true
            }
            return runCommands(press, in: .typing)
        }

        return handleCommandMode(press)
    }

    // MARK: - Commands

    /// Runs the first command bound to the press that applies right now.
    @discardableResult
    func runCommands(_ press: KeyPress, in mode: KeyMode) -> Bool {
        if handleTabChord(press) { return true }
        if press.command, !press.shift, !press.option, !press.control {
            switch press.key {
            case .character("w"):
                // Close the chat before the window.
                guard chatOpen else { return false }
                toggleChat()
                return true
            case .character("v") where mode == .command:
                // Text fields paste for themselves.
                pasteIntoDraft()
                return true
            default:
                break
            }
        }
        let keymap = self.keymap
        for command in Command.allCases {
            if command.yieldsToText, mode != .command { continue }
            let bound = keymap.chords(for: command).contains { $0.matches(press) && mode.allows($0) }
            if bound, perform(command) { return true }
        }
        return false
    }

    /// Command and a number switch the chat's tabs; Option and a number
    /// switch the code panel's tools. Each opens its pane when it's closed.
    private func handleTabChord(_ press: KeyPress) -> Bool {
        guard press.command != press.option, !press.control, !press.shift,
              case let .character(character) = press.key,
              let digit = Int(String(character)), (1...9).contains(digit) else { return false }
        let index = digit - 1
        if press.option {
            guard WorkspaceTool.allCases.indices.contains(index) else { return true }
            Motion.perform(Motion.tabContent) { setWorkspaceTool(WorkspaceTool.allCases[index]) }
        } else {
            guard store.selectedAgentID != nil, ChatTab.allCases.indices.contains(index) else { return true }
            openChat()
            Motion.perform(Motion.tabContent) { setChatTab(ChatTab.allCases[index]) }
        }
        return true
    }

    /// Does what a command says. Returns false when it doesn't apply right
    /// now, so the next command bound to the same key gets a turn.
    func perform(_ command: Command) -> Bool {
        let selected = store.selectedAgent
        switch command {
        case .focusChatBox:
            focusInput()
        case .toggleChat:
            if selected == nil { focusInput() } else { toggleChat() }
        case .menu:
            toggleMenu(.main, animated: true)
        case .search:
            toggleSearch()
        case .shortcuts:
            if overlay == .shortcuts { closeOverlay(animated: true) } else { open(.shortcuts, animated: true) }
        case .settings:
            if overlay == .settings { closeOverlay(animated: true) } else { open(.settings, animated: true) }

        case .approve, .approveAlways, .deny:
            guard let agent = selected, agent.phase == .awaitingApproval else { return false }
            let decision: ApprovalDecision = switch command {
            case .approve: .accept
            case .approveAlways: .acceptForSession
            default: .decline
            }
            store.respond(decision, to: agent.id)
        case .stop:
            guard let agent = selected, agent.phase.isActive else { return false }
            store.interrupt(agent.id)

        case .newAgent:
            beginNewAgent()
        case .selectAgent:
            open(.picker, animated: true)
        case .nextAgent, .previousAgent:
            cycle(forward: command == .nextAgent)
        case .cycleFilter:
            nextFilter()
        case .nearestLeft:
            selectNeighbor(CGVector(dx: -1, dy: 0))
        case .nearestDown:
            selectNeighbor(CGVector(dx: 0, dy: 1))
        case .nearestUp:
            selectNeighbor(CGVector(dx: 0, dy: -1))
        case .nearestRight:
            selectNeighbor(CGVector(dx: 1, dy: 0))
        case .rename, .archive, .delete:
            guard let agent = selected else {
                store.toast(.init(text: "Select an agent first"))
                return true
            }
            switch command {
            case .rename: beginRename(agent.id)
            case .archive: archive(agent.id)
            default: open(.confirmDelete(agent.id), animated: true)
            }
        case .restoreArchived:
            guard !store.archivedAgents.isEmpty else {
                flash("Nothing is archived")
                return true
            }
            toggleMenu(.archived, animated: true)
        case .undo:
            return store.performToastAction()

        case .queueMessage:
            guard canSend else { return false }
            submitDraft(queue: true)
        case .previousTab, .nextTab:
            guard selected != nil else { return false }
            stepChatTab(command == .nextTab ? 1 : -1)
        case .attachFiles:
            chooseAttachments()
        case .split:
            toggleSplit()
        case .swapSides:
            store.swapPinned()

        case .codePanel:
            toggleWorkspace()
        case .statusPane:
            toggleStatusPane()
        case .goToAgent:
            guard let agent = selected else { return false }
            center(on: agent, animated: true)
        case .zoomToFit:
            zoomToFit(animated: true)
        case .zoomIn:
            zoomStep(1.25)
        case .zoomOut:
            zoomStep(0.8)
        case .projects:
            if store.projects.isEmpty {
                addProjectFromPanel()
            } else {
                toggleMenu(.projects, animated: true)
            }
        case .addProject:
            addProjectFromPanel()
        }
        return true
    }

    // MARK: - Command mode

    private func handleCommandMode(_ press: KeyPress) -> Bool {
        if press.key == .escape, !press.hasModifier {
            if chatOpen {
                toggleChat()
            } else if workspaceOpen {
                toggleWorkspace()
            } else if statusPaneOpen {
                toggleStatusPane()
            } else {
                store.select(nil)
            }
            return true
        }

        // The number keys pick an answer to a pending question.
        if !press.hasModifier, case let .character(character) = press.key,
           let digit = Int(String(character)), (1...9).contains(digit) {
            chooseAnswer(digit - 1)
            return true
        }

        if runCommands(press, in: .command) { return true }

        // Swallow stray letters so they don't beep.
        if !press.hasModifier, case let .character(character) = press.key {
            return character.isLetter || character.isNumber
        }
        return false
    }

    /// Deletes an agent for good, after the user confirmed.
    func confirmDelete(_ id: AgentID) {
        closeOverlay(animated: true)
        Motion.perform(Motion.snappy) {
            store.delete(id)
            if store.selectedAgentID == nil { chatOpen = false }
        }
    }

    func stepChatTab(_ delta: Int) {
        guard store.selectedAgentID != nil else { return }
        let tabs = ChatTab.allCases
        let current = tabs.firstIndex(of: chatTab) ?? 0
        openChat()
        Motion.perform(Motion.tabContent) {
            setChatTab(tabs[(current + delta + tabs.count) % tabs.count])
        }
    }

    // MARK: - Menus

    /// A menu takes the keys that move through it: the arrows, Return, Esc,
    /// and the numbers of its choices. Every other key does what it does
    /// anywhere, and the menu closes behind it.
    private func handleMenuKey(_ press: KeyPress, menu id: MenuID) -> Bool {
        let menu = menu(for: id)
        let enabled = menu.items.indices.filter { menu.items[$0].isEnabled }

        switch press.key {
        case .escape where !press.hasModifier:
            // Submenus step back to the menu that opened them.
            if let parent = menu.parent {
                open(.menu(parent), animated: false)
            } else {
                closeOverlay(animated: true)
            }
            return true
        case .down where !press.hasModifier:
            moveMenuHighlight(1, enabled: enabled)
            return true
        case .up where !press.hasModifier:
            moveMenuHighlight(-1, enabled: enabled)
            return true
        case .enter where !press.hasModifier:
            if menu.items.indices.contains(menuHighlight) { activate(menu.items[menuHighlight]) }
            return true
        case .right where !press.hasModifier:
            if menu.items.indices.contains(menuHighlight), menu.items[menuHighlight].opensSubmenu {
                activate(menu.items[menuHighlight])
            }
            return true
        case .left where !press.hasModifier:
            if let parent = menu.parent { open(.menu(parent), animated: false) }
            return true
        default:
            break
        }

        if let item = menu.items.first(where: { $0.choice?.matches(press) == true }) {
            activate(item)
            return true
        }
        if runCommands(press, in: .command), overlay == .menu(id) {
            closeOverlay(animated: true)
        }
        return true
    }

    /// Runs a menu row. A row that doesn't open another menu closes this one.
    func activate(_ item: KeyMenu.Item) {
        guard item.isEnabled else { return }
        let before = overlay
        item.action()
        if !item.opensSubmenu, overlay == before { closeOverlay(animated: true) }
    }

    private func moveMenuHighlight(_ delta: Int, enabled: [Int]) {
        guard !enabled.isEmpty else { return }
        let position = enabled.firstIndex(of: menuHighlight) ?? (delta > 0 ? -1 : 0)
        menuHighlight = enabled[(position + delta + enabled.count) % enabled.count]
    }

    // MARK: - Agent picker

    /// Agents that match the picker's search text, best match first.
    var pickerResults: [AgentModel] {
        let query = pickerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let agents = store.canvasOrder
        guard !query.isEmpty else {
            // Agents that want the user come first.
            return agents.sorted { ($0.needsAttention ? 0 : 1) < ($1.needsAttention ? 0 : 1) }
        }
        func score(_ agent: AgentModel) -> Int? {
            let name = agent.name.lowercased()
            if name.hasPrefix(query) { return 0 }
            if name.contains(query) { return 1 }
            if agent.title.lowercased().contains(query) { return 2 }
            if store.project(agent.projectID)?.title.lowercased().contains(query) == true { return 3 }
            if agent.phase.label.lowercased().contains(query) { return 4 }
            return nil
        }
        return agents.compactMap { agent in score(agent).map { (agent, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func handlePickerKey(_ press: KeyPress) -> Bool {
        let results = pickerResults
        switch press.key {
        case .escape:
            closeOverlay(animated: true)
            focus.blur()
        case .down:
            if !results.isEmpty { pickerHighlight = (pickerHighlight + 1) % results.count }
        case .up:
            if !results.isEmpty { pickerHighlight = (pickerHighlight - 1 + results.count) % results.count }
        case .tab:
            if !results.isEmpty {
                pickerHighlight = (pickerHighlight + (press.shift ? results.count - 1 : 1)) % results.count
            }
        case .enter:
            if results.indices.contains(pickerHighlight) {
                let agent = results[pickerHighlight]
                closeOverlay(animated: true)
                focus.blur()
                select(agent.id, openChat: chatOpen)
            }
        default:
            // Everything else types into the search field.
            return false
        }
        return true
    }

    // MARK: - Changing shortcuts

    /// Starts listening for the next key press, which becomes the shortcut in `slot`.
    func beginRecording(_ slot: ShortcutSlot) {
        shortcutNote = nil
        recordingShortcut = slot
    }

    private func recordShortcut(_ press: KeyPress, into slot: ShortcutSlot) {
        recordingShortcut = nil
        let chord = KeyChord(press)
        switch press.key {
        case .escape where !press.hasModifier:
            return
        case .delete where !press.hasModifier:
            if let index = slot.index {
                settings.keymap.removeChord(at: index, from: slot.command)
            }
            return
        default:
            break
        }
        if Keymap.isReserved(chord) {
            shortcutNote = "\(chord.label) is kept for the app. Try another key."
            return
        }
        let taken = settings.keymap.assign(chord, to: slot.command, replacing: slot.index)
        if let other = taken.first {
            shortcutNote = "\(chord.label) moved here from “\(other.title)”."
        } else if !chord.worksWhileTyping {
            shortcutNote = "\(chord.label) works while the chat box doesn't have the keyboard."
        }
    }
}

/// One shortcut being changed: a command, and which of its chords. A nil
/// index adds a chord.
struct ShortcutSlot: Equatable {
    var command: Command
    var index: Int?
}

extension FocusCoordinator {
    /// True while the embedded terminal has the keyboard.
    var isTerminalFocused: Bool {
        guard let responder = firstResponder else { return false }
        return String(describing: type(of: responder)).contains("Terminal")
    }
}
