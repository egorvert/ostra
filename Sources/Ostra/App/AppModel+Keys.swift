import AppKit
import OstraCore
import SwiftUI

/// The keyboard model.
///
/// Ostra is modal. While the chat box has focus, keys type text and Esc
/// leaves. Otherwise single keys are commands: A adds, S selects, D deletes,
/// M opens the menu. Shortcuts with Command or Control work in both modes.
extension AppModel {
    /// Routes a key press. Returns true when the press is consumed.
    func handle(_ press: KeyPress, event: NSEvent) -> Bool {
        // Sheets and open panels run their own keyboard.
        guard let window = event.window, window === NSApp.mainWindow, window.attachedSheet == nil else {
            return false
        }
        return route(press)
    }

    /// Applies the keymap to a press, whatever produced it.
    func route(_ press: KeyPress) -> Bool {
        if press.command { return handleCommandShortcut(press) }

        if press.control, press.key == .tab {
            cycle(forward: !press.shift)
            return true
        }

        switch overlay {
        case let .menu(id):
            return handleMenuKey(press, menu: id)
        case .picker:
            return handlePickerKey(press)
        case let .confirmDelete(id):
            if press.key == .enter || press.isCharacter("y") {
                closeOverlay()
                store.delete(id)
                if store.selectedAgentID == nil { chatOpen = false }
            } else if press.key == .escape || press.isCharacter("n") {
                closeOverlay()
            }
            return true
        case .settings, .shortcuts:
            if press.key == .escape {
                closeOverlay(animated: true)
                return true
            }
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
            return false
        }

        if focus.isEditingText {
            if press.key == .escape {
                focus.blur()
                return true
            }
            if press.control, press.key == .character("c"), let id = store.selectedAgentID {
                store.interrupt(id)
                return true
            }
            return false
        }

        return handleCommandMode(press)
    }

    // MARK: - Command and Control shortcuts

    private func handleCommandShortcut(_ press: KeyPress) -> Bool {
        switch press.key {
        case .character(","):
            open(.settings, animated: true)
        case .character("k"):
            toggleMenu(.main, animated: false)
        case .character("/"), .character("?"):
            open(.shortcuts, animated: true)
        case .character("n"):
            beginNewAgent()
        case .character("."):
            if let id = store.selectedAgentID { store.interrupt(id) }
        case .character("\\"):
            toggleSplit()
        case .character("0"):
            zoomToFit(animated: true)
        case .character("="), .character("+"):
            zoomStep(1.25)
        case .character("-"):
            zoomStep(0.8)
        case .character("j"):
            toggleWorkspace(animated: true)
        case .character("["):
            stepChatTab(-1)
        case .character("]"):
            stepChatTab(1)
        case .character("w"):
            // Close the chat before the window.
            guard chatOpen else { return false }
            toggleChat(animated: true)
        case .character("z"):
            guard !focus.isEditingText else { return false }
            return store.performToastAction()
        case .enter:
            if let agent = store.selectedAgent, agent.phase == .awaitingApproval {
                respond(press.shift ? .acceptForSession : .accept)
            } else {
                submitDraft(queue: press.shift)
            }
        case .delete:
            guard let agent = store.selectedAgent, agent.phase == .awaitingApproval else { return false }
            respond(.decline)
        case let .character(digit) where ("1"..."4").contains(digit):
            let tools = WorkspaceTool.allCases
            setWorkspaceTool(tools[Int(String(digit))! - 1])
        default:
            return false
        }
        return true
    }

    // MARK: - Command mode

    private func handleCommandMode(_ press: KeyPress) -> Bool {
        guard !press.option, !press.control else { return false }

        switch press.key {
        case .escape:
            if chatOpen {
                toggleChat(animated: false)
            } else if workspaceOpen {
                toggleWorkspace(animated: false)
            } else if statusPaneOpen {
                statusPaneOpen = false
            } else {
                store.select(nil)
            }
        case .enter:
            focusInput()
        case .space:
            if store.selectedAgentID == nil {
                focusInput()
            } else {
                toggleChat(animated: false)
                if chatOpen, let agent = store.selectedAgent { reveal(agent, animated: true) }
            }
        case .tab:
            cycle(forward: !press.shift)
        case .left:
            selectNeighbor(CGVector(dx: -1, dy: 0))
        case .right:
            selectNeighbor(CGVector(dx: 1, dy: 0))
        case .up:
            selectNeighbor(CGVector(dx: 0, dy: -1))
        case .down:
            selectNeighbor(CGVector(dx: 0, dy: 1))
        case .delete:
            return false
        case let .character(character):
            return handleCommandCharacter(character, shift: press.shift)
        }
        return true
    }

    private func handleCommandCharacter(_ character: Character, shift: Bool) -> Bool {
        // A pending question takes the number keys.
        if let digit = Int(String(character)), (1...9).contains(digit),
           let agent = store.selectedAgent, agent.phase == .awaitingInput {
            chooseAnswer(digit - 1)
            return true
        }

        switch character {
        case "a":
            toggleMenu(.add, animated: false)
        case "s":
            open(.picker, animated: false)
        case "d":
            guard let id = store.selectedAgentID else {
                store.toast(.init(text: "Select an agent first"))
                return true
            }
            if shift {
                open(.confirmDelete(id), animated: false)
            } else {
                archiveSelected()
            }
        case "m":
            toggleMenu(.main, animated: false)
        case "c":
            toggleWorkspace(animated: false)
        case "i":
            focusInput()
        case "f":
            nextFilter()
        case "h":
            selectNeighbor(CGVector(dx: -1, dy: 0))
        case "l":
            selectNeighbor(CGVector(dx: 1, dy: 0))
        case "k":
            selectNeighbor(CGVector(dx: 0, dy: -1))
        case "j":
            selectNeighbor(CGVector(dx: 0, dy: 1))
        case "y":
            respond(shift ? .acceptForSession : .accept)
        case "n":
            respond(.decline)
        case "x":
            if let id = store.selectedAgentID { store.interrupt(id) }
        case "z":
            store.performToastAction()
        case "g":
            if let agent = store.selectedAgent { center(on: agent, animated: true) }
        case "0":
            zoomToFit(animated: true)
        case "=", "+":
            zoomStep(1.25)
        case "-":
            zoomStep(0.8)
        case "1", "2", "3":
            guard store.selectedAgentID != nil else { return true }
            chatOpen = true
            setChatTab(ChatTab.allCases[Int(String(character))! - 1])
        case "[":
            stepChatTab(-1)
        case "]":
            stepChatTab(1)
        case "\\":
            toggleSplit()
        case "|":
            store.swapPinned()
        case "t":
            statusPaneOpen.toggle()
        case "?", "/":
            open(.shortcuts, animated: false)
        case ",":
            open(.settings, animated: false)
        default:
            // Swallow stray letters so they don't beep.
            return character.isLetter || character.isNumber
        }
        return true
    }

    func stepChatTab(_ delta: Int) {
        guard store.selectedAgentID != nil else { return }
        let tabs = ChatTab.allCases
        let current = tabs.firstIndex(of: chatTab) ?? 0
        chatOpen = true
        setChatTab(tabs[(current + delta + tabs.count) % tabs.count])
    }

    // MARK: - Menus

    private func handleMenuKey(_ press: KeyPress, menu id: MenuID) -> Bool {
        let menu = menu(for: id)
        let enabled = menu.items.indices.filter { menu.items[$0].isEnabled }

        switch press.key {
        case .escape:
            // Submenus step back to the menu that opened them.
            if let parent = menu.parent {
                open(.menu(parent), animated: false)
            } else {
                closeOverlay()
            }
        case .down:
            moveMenuHighlight(1, enabled: enabled)
        case .up:
            moveMenuHighlight(-1, enabled: enabled)
        case .tab:
            moveMenuHighlight(press.shift ? -1 : 1, enabled: enabled)
        case .enter, .space, .right:
            if menu.items.indices.contains(menuHighlight), menu.items[menuHighlight].isEnabled {
                menu.items[menuHighlight].action()
            }
        case .left:
            if let parent = menu.parent { open(.menu(parent), animated: false) }
        case .delete:
            break
        case let .character(character):
            if let item = menu.items.first(where: { $0.key == .character(character) && $0.isEnabled }) {
                item.action()
            } else if character == "m", id == .main {
                closeOverlay()
            } else if character == "a", id == .add {
                closeOverlay()
            }
        }
        return true
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
            closeOverlay()
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
                closeOverlay()
                focus.blur()
                select(agent.id, openChat: chatOpen)
                center(on: agent, animated: true)
            }
        default:
            // Everything else types into the search field.
            return false
        }
        return true
    }
}

extension FocusCoordinator {
    /// True while the embedded terminal has the keyboard.
    var isTerminalFocused: Bool {
        guard let responder = firstResponder else { return false }
        return String(describing: type(of: responder)).contains("Terminal")
    }
}
