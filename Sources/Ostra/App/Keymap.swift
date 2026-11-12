import Foundation

/// A key and the modifiers held with it: what a shortcut matches.
struct KeyChord: Hashable {
    var key: KeyCode
    var shift = false
    var control = false
    var option = false
    var command = false

    init(_ key: KeyCode, shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
        self.key = Self.normalize(key)
        // A punctuation character already says whether Shift was down: "?" is Shift-"/".
        self.shift = Self.carriesShift(self.key) ? false : shift
        self.control = control
        self.option = option
        self.command = command
    }

    /// The chord a key press makes.
    init(_ press: KeyPress) {
        self.init(press.key, shift: press.shift, control: press.control, option: press.option, command: press.command)
    }

    /// A plain character key.
    static func key(_ character: Character) -> KeyChord { KeyChord(.character(character)) }

    /// A character with Command.
    static func cmd(_ character: Character, shift: Bool = false) -> KeyChord {
        KeyChord(.character(character), shift: shift, command: true)
    }

    func matches(_ press: KeyPress) -> Bool {
        guard press.control == control, press.option == option, press.command == command,
              Self.normalize(press.key) == key else { return false }
        return Self.carriesShift(key) || press.shift == shift
    }

    /// True when the chord works while a text field has the keyboard: it
    /// holds Command or Control, or it's Tab, which the chat box doesn't type.
    var worksWhileTyping: Bool {
        command || control || key == .tab
    }

    /// The chord as macOS menus write it, such as "⇧⌘↩".
    var label: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + key.label
    }

    // MARK: Normalizing

    /// "=" and "+" share a key, so a shortcut on one answers to both.
    private static func normalize(_ key: KeyCode) -> KeyCode {
        key == .character("=") ? .character("+") : key
    }

    private static func carriesShift(_ key: KeyCode) -> Bool {
        if case let .character(character) = key { return !character.isLetter }
        return false
    }

    // MARK: Text form

    /// The chord as text, such as "cmd+shift+enter". Settings store it this way.
    var spec: String {
        var tokens: [String] = []
        if control { tokens.append("ctrl") }
        if option { tokens.append("opt") }
        if shift { tokens.append("shift") }
        if command { tokens.append("cmd") }
        tokens.append(Self.token(for: key))
        return tokens.joined(separator: "+")
    }

    init?(spec: String) {
        // "+" separates tokens, so the plus key is spelled "plus".
        var tokens = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = tokens.popLast(), let key = Self.key(named: name) else { return nil }
        self.init(
            key,
            shift: tokens.contains("shift"),
            control: tokens.contains("ctrl"),
            option: tokens.contains("opt"),
            command: tokens.contains("cmd")
        )
    }

    private static func token(for key: KeyCode) -> String {
        switch key {
        case .escape: "esc"
        case .enter: "enter"
        case .tab: "tab"
        case .space: "space"
        case .delete: "delete"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .character("+"): "plus"
        case let .character(character): String(character)
        }
    }

    static func key(named name: String) -> KeyCode? {
        switch name {
        case "esc": .escape
        case "enter": .enter
        case "tab": .tab
        case "space": .space
        case "delete": .delete
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        case "plus": .character("+")
        default: name.count == 1 ? .character(name.first!) : nil
        }
    }
}

/// Everything a shortcut can do. Each command has default keys, and the
/// shortcuts sheet lets the user change them.
///
/// When two commands share a key, the one listed first runs if it applies:
/// Shift-Command-Return allows an action while one waits, and queues a
/// message otherwise.
enum Command: String, CaseIterable, Identifiable {
    // Basics
    case focusChatBox
    case toggleChat
    case menu
    case search
    case shortcuts
    case settings
    // Requests
    case approve
    case approveAlways
    case deny
    case stop
    // Agents
    case newAgent
    case selectAgent
    case nextAgent
    case previousAgent
    case cycleFilter
    case nearestLeft
    case nearestDown
    case nearestUp
    case nearestRight
    case rename
    case archive
    case delete
    case restoreArchived
    case undo
    // Chat
    case queueMessage
    case previousTab
    case nextTab
    case attachFiles
    case split
    case swapSides
    // Panels and canvas
    case codePanel
    case statusPane
    case goToAgent
    case zoomToFit
    case zoomIn
    case zoomOut
    case projects
    case addProject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusChatBox: "Type in the chat box"
        case .toggleChat: "Open or close the chat"
        case .menu: "Open the menu"
        case .search: "Search everything"
        case .shortcuts: "Shortcuts"
        case .settings: "Settings"
        case .approve: "Allow"
        case .approveAlways: "Always allow"
        case .deny: "Deny"
        case .stop: "Stop the agent"
        case .newAgent: "New agent"
        case .selectAgent: "Select an agent by name"
        case .nextAgent: "Next agent"
        case .previousAgent: "Previous agent"
        case .cycleFilter: "Change what Tab visits"
        case .nearestLeft: "Nearest agent to the left"
        case .nearestDown: "Nearest agent below"
        case .nearestUp: "Nearest agent above"
        case .nearestRight: "Nearest agent to the right"
        case .rename: "Rename the agent"
        case .archive: "Archive the agent"
        case .delete: "Delete the agent for good"
        case .restoreArchived: "Restore an archived agent"
        case .undo: "Undo an archive"
        case .queueMessage: "Queue behind the current run"
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .attachFiles: "Attach files"
        case .split: "Split the chat in two"
        case .swapSides: "Swap the two sides"
        case .codePanel: "Open or close the code panel"
        case .statusPane: "Show or hide the status pane"
        case .goToAgent: "Go to the selected agent"
        case .zoomToFit: "Zoom to fit"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .projects: "Project for new agents"
        case .addProject: "Add a project folder"
        }
    }

    var defaultChords: [KeyChord] {
        switch self {
        case .focusChatBox: [KeyChord(.enter)]
        case .toggleChat: [KeyChord(.space)]
        case .menu: [.key("m")]
        case .search: [.cmd("k")]
        case .shortcuts: [.key("?"), .cmd("/")]
        case .settings: [.key(","), .cmd(",")]
        case .approve: [.key("y"), KeyChord(.enter, command: true)]
        case .approveAlways: [KeyChord(.character("y"), shift: true), KeyChord(.enter, shift: true, command: true)]
        case .deny: [.key("n"), KeyChord(.delete, command: true)]
        case .stop: [.key("x"), .cmd("."), KeyChord(.character("c"), control: true)]
        case .newAgent: [.key("a"), .cmd("n")]
        case .selectAgent: [.key("s")]
        case .nextAgent: [KeyChord(.tab)]
        case .previousAgent: [KeyChord(.tab, shift: true)]
        case .cycleFilter: [.key("f")]
        case .nearestLeft: [KeyChord(.left)]
        case .nearestDown: [KeyChord(.down)]
        case .nearestUp: [KeyChord(.up)]
        case .nearestRight: [KeyChord(.right)]
        case .rename: [.key("r")]
        case .archive: [.key("d")]
        case .delete: [KeyChord(.character("d"), shift: true)]
        case .restoreArchived: [.key("u")]
        case .undo: [.key("z"), .cmd("z")]
        case .queueMessage: [KeyChord(.enter, shift: true, command: true)]
        case .previousTab: [.key("["), .cmd("[")]
        case .nextTab: [.key("]"), .cmd("]")]
        case .attachFiles: [.cmd("u")]
        case .split: [.key("\\"), .cmd("\\")]
        case .swapSides: [.key("|")]
        case .codePanel: [.key("c"), .cmd("j")]
        case .statusPane: [.key("t")]
        case .goToAgent: [.key("g")]
        case .zoomToFit: [.key("0"), .cmd("0")]
        case .zoomIn: [.key("+"), .cmd("+")]
        case .zoomOut: [.key("-"), .cmd("-")]
        case .projects: [.key("p")]
        case .addProject: [.cmd("o")]
        }
    }

    /// True for commands that leave their keys to a focused text field or
    /// terminal, which has its own undo.
    var yieldsToText: Bool {
        self == .undo
    }
}

/// The keys bound to every command: the defaults, with the user's changes on top.
struct Keymap {
    /// Chords by command, as text. A command missing here keeps its defaults.
    var overrides: [String: [String]] = [:]

    func chords(for command: Command) -> [KeyChord] {
        guard let specs = overrides[command.rawValue] else { return command.defaultChords }
        return specs.compactMap(KeyChord.init(spec:))
    }

    func isCustomized(_ command: Command) -> Bool {
        overrides[command.rawValue] != nil && chords(for: command) != command.defaultChords
    }

    /// The commands bound to a press, in the order they get to try it.
    func commands(for press: KeyPress) -> [Command] {
        Command.allCases.filter { command in
            chords(for: command).contains { $0.matches(press) }
        }
    }

    /// The commands other than `command` that use `chord`.
    func commands(using chord: KeyChord, except command: Command) -> [Command] {
        Command.allCases.filter { $0 != command && chords(for: $0).contains(chord) }
    }

    /// The label to show beside a control: a single key while the chat box
    /// is free, and a chord that works while typing otherwise.
    func label(for command: Command, typing: Bool = false) -> String? {
        let chords = chords(for: command)
        if typing {
            return chords.first(where: \.worksWhileTyping)?.label
        }
        return (chords.first { !$0.command && !$0.control && !$0.option } ?? chords.first)?.label
    }

    // MARK: Changes

    mutating func setChords(_ chords: [KeyChord], for command: Command) {
        if chords == command.defaultChords {
            overrides[command.rawValue] = nil
        } else {
            overrides[command.rawValue] = chords.map(\.spec)
        }
    }

    /// Binds `chord` to `command`, in place of the chord at `index` or after
    /// the others, and takes it from any command that had it. Returns the
    /// commands it was taken from.
    @discardableResult
    mutating func assign(_ chord: KeyChord, to command: Command, replacing index: Int?) -> [Command] {
        let previous = commands(using: chord, except: command)
        for other in previous {
            setChords(chords(for: other).filter { $0 != chord }, for: other)
        }
        var list = chords(for: command)
        if let existing = list.firstIndex(of: chord) {
            // Already bound here: replacing a different slot just drops that slot.
            if let index, index != existing, list.indices.contains(index) { list.remove(at: index) }
        } else if let index, list.indices.contains(index) {
            list[index] = chord
        } else {
            list.append(chord)
        }
        setChords(list, for: command)
        return previous
    }

    mutating func removeChord(at index: Int, from command: Command) {
        var list = chords(for: command)
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        setChords(list, for: command)
    }

    mutating func reset(_ command: Command) {
        overrides[command.rawValue] = nil
    }

    /// Chords the app keeps for itself: Esc, the number keys, and the
    /// system's text and window shortcuts.
    static func isReserved(_ chord: KeyChord) -> Bool {
        if chord.key == .escape { return true }
        if case let .character(character) = chord.key {
            // 1–9 pick answers, Command and a number pick chat tabs, and
            // Option and a number pick code panel tools.
            if character.isNumber, character != "0", !chord.control, !chord.shift, !(chord.command && chord.option) {
                return true
            }
            if chord.command, !chord.control, !chord.option, !chord.shift, "qwhvcxa".contains(character) {
                return true
            }
        }
        return false
    }
}

/// Every shortcut, grouped for the shortcuts sheet. Rows with commands can
/// be changed; fixed rows describe keys the app keeps for itself.
enum ShortcutCatalog {
    struct Row: Identifiable {
        enum Kind {
            case commands([Command])
            case fixed([String])
        }

        var title: String
        var kind: Kind
        var id: String { title }

        static func command(_ command: Command) -> Row {
            Row(title: command.title, kind: .commands([command]))
        }

        static func fixed(_ title: String, _ keys: String...) -> Row {
            Row(title: title, kind: .fixed(keys))
        }
    }

    struct Section: Identifiable {
        var title: String
        var rows: [Row]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Basics", rows: [
            .command(.focusChatBox),
            .fixed("Leave the chat box, close a panel", "esc"),
            .command(.toggleChat),
            .command(.menu),
            .command(.search),
            .command(.shortcuts),
            .command(.settings),
        ]),
        Section(title: "Agents", rows: [
            .command(.newAgent),
            .command(.selectAgent),
            .command(.nextAgent),
            .command(.previousAgent),
            .command(.cycleFilter),
            Row(title: "Nearest agent", kind: .commands([.nearestLeft, .nearestDown, .nearestUp, .nearestRight])),
            .command(.rename),
            .command(.archive),
            .command(.undo),
            .command(.restoreArchived),
            .command(.delete),
        ]),
        Section(title: "Requests", rows: [
            .command(.approve),
            .command(.approveAlways),
            .command(.deny),
            .fixed("Pick an answer", "1", "–", "9"),
            .command(.stop),
        ]),
        Section(title: "Chat", rows: [
            .fixed("Send", "↩"),
            .fixed("New line", "⇧↩"),
            .command(.queueMessage),
            .fixed("Switch tabs", "⌘1", "–", "⌘3"),
            .command(.previousTab),
            .command(.nextTab),
            .command(.attachFiles),
            .fixed("Paste text, images, or files", "⌘V"),
            .command(.split),
            .command(.swapSides),
        ]),
        Section(title: "Panels", rows: [
            .command(.codePanel),
            .fixed("Code panel tools", "⌥1", "–", "⌥4"),
            .fixed("Leave the terminal", "⇧esc"),
            .command(.statusPane),
        ]),
        Section(title: "Canvas", rows: [
            .command(.goToAgent),
            .command(.zoomToFit),
            .command(.zoomIn),
            .command(.zoomOut),
            .command(.projects),
            .command(.addProject),
        ]),
    ]
}
