import AppKit

/// A key, independent of the keyboard layout where that's possible.
enum KeyCode: Hashable {
    case character(Character)
    case escape
    case enter
    case tab
    case space
    case delete
    case up
    case down
    case left
    case right

    /// The label for a keycap.
    var label: String {
        switch self {
        case let .character(character): String(character).uppercased()
        case .escape: "esc"
        case .enter: "↩"
        case .tab: "⇥"
        case .space: "space"
        case .delete: "⌫"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }
}

/// One key-down event, reduced to what the keymap needs.
struct KeyPress {
    var key: KeyCode
    var shift: Bool
    var control: Bool
    var option: Bool
    var command: Bool

    var hasModifier: Bool { control || option || command }

    init(key: KeyCode, shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
        self.key = key
        self.shift = shift
        self.control = control
        self.option = option
        self.command = command
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        shift = flags.contains(.shift)
        control = flags.contains(.control)
        option = flags.contains(.option)
        command = flags.contains(.command)

        switch event.keyCode {
        case 53: key = .escape
        case 36, 76: key = .enter
        case 48: key = .tab
        case 49: key = .space
        case 51, 117: key = .delete
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
        default:
            // Shift changes the character ("?" for "/"), so keep the shifted
            // form for punctuation and fold letters to lowercase.
            guard let characters = event.charactersIgnoringModifiers, let first = characters.first else {
                return nil
            }
            key = .character(first.isLetter ? Character(first.lowercased()) : first)
        }
    }

    /// True for a plain press of `character`, with Shift allowed only when `shifted` says so.
    func isCharacter(_ character: Character, shifted: Bool = false) -> Bool {
        guard !hasModifier, key == .character(character) else { return false }
        return shift == shifted
    }
}
