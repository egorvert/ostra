import OstraCore
import SwiftUI

/// A menu whose every row shows the key that runs it.
struct KeyMenuView: View {
    let menu: KeyMenu
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(menu.title)
                .font(Theme.ui(12, .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 5)

            ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                KeyMenuRow(item: item, highlighted: app.menuHighlight == index)
                    .onHover { inside in
                        if inside, item.isEnabled { app.menuHighlight = index }
                    }
                    .onTapGesture { app.activate(item) }
            }

            if let footer = menu.footer {
                Text(footer)
                    .font(Theme.text(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
        .padding(6)
        .frame(width: 252)
        .glassPanel(cornerRadius: 20, frost: app.settings.data.panelFrost)
    }
}

private struct KeyMenuRow: View {
    let item: KeyMenu.Item
    var highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            // A fixed column, so titles line up when a key is wider than one letter.
            Keycap(item.key ?? "", size: 20, prominent: highlighted && item.isEnabled)
                .opacity(item.key == nil ? 0 : 1)
                .frame(width: 30, alignment: .leading)
            Text(item.title)
                .font(Theme.ui(13))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let detail = item.detail {
                Text(detail)
                    .font(Theme.text(12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if item.isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            // The row's corner follows the menu's: its radius less the inset.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(highlighted && item.isEnabled ? 0.07 : 0))
        }
        .opacity(item.isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
    }
}

/// The Select menu: type to filter agents, arrows to move, Return to jump.
struct AgentPickerView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        let results = app.pickerResults

        VStack(alignment: .leading, spacing: 4) {
            TextField("Select an agent", text: $app.pickerQuery)
                .textFieldStyle(.plain)
                .font(Theme.text(14))
                .focused($searchFocused)
                .padding(.horizontal, 10)
                .frame(height: 34)

            Hairline().padding(.horizontal, 6)

            if results.isEmpty {
                Text(app.store.agents.isEmpty ? "No agents yet" : "No match")
                    .font(Theme.text(12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, agent in
                                AgentRow(agent: agent, highlighted: index == app.pickerHighlight)
                                    .id(agent.id)
                                    .onTapGesture {
                                        app.closeOverlay()
                                        app.select(agent.id, openChat: app.chatOpen)
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: app.pickerHighlight) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 320)
        .glassPanel(cornerRadius: 20, frost: app.settings.data.panelFrost)
        .onAppear { searchFocused = true }
        .onChange(of: app.pickerQuery) { _, _ in app.pickerHighlight = 0 }
    }
}

/// Full-window overlays: settings, the shortcuts sheet, and the delete confirmation.
struct ModalLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            switch app.overlay {
            case .settings:
                backdrop
                SettingsView()
                    .transition(.sheet)
            case .shortcuts:
                backdrop
                ShortcutsView()
                    .transition(.sheet)
            case let .confirmDelete(id):
                backdrop
                ConfirmDeleteView(agentID: id)
                    .transition(.sheet)
            case .search:
                backdrop
                // The transition sits on the panel itself, so it scales
                // from the panel's top edge, not the window's.
                SearchView()
                    .transition(.palette)
                    .hudRegion("search", in: app.hudRegions)
                    .padding(.top, max(72, app.viewSize.height * 0.16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backdrop: some View {
        Color.black.opacity(0.10)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { app.closeOverlay(animated: true) }
            .hudRegion("modal", in: app.hudRegions)
            .transition(.opacity)
    }
}

private struct ConfirmDeleteView: View {
    let agentID: AgentID
    @Environment(AppModel.self) private var app

    var body: some View {
        let agent = app.store.agent(agentID)
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \(agent?.name ?? "this agent")?")
                .font(Theme.ui(16, .medium))
            Text("The agent and its conversation go for good. Files it changed stay as they are.")
                .font(Theme.text(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Spacer()
                Button {
                    app.closeOverlay(animated: true)
                } label: {
                    HStack(spacing: 5) {
                        Text("Cancel").font(Theme.ui(13, .medium))
                        Text("esc").font(Theme.mono(11, .medium)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(height: 28)
                }
                .buttonStyle(.pressable)
                Button {
                    app.confirmDelete(agentID)
                } label: {
                    HStack(spacing: 6) {
                        Text("Delete").font(Theme.ui(13, .medium))
                        Text("↩").font(Theme.mono(11, .medium)).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(Theme.red))
                }
                .buttonStyle(.pressable)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 340)
        .glassPanel(cornerRadius: 24, frost: 0.6)
    }
}

/// Every shortcut in one sheet. Clicking a shortcut records a new one.
struct ShortcutsView: View {
    @Environment(AppModel.self) private var app

    /// Three columns, balanced by hand so they end near the same line.
    private static let columns: [[String]] = [
        ["Basics", "Requests"],
        ["Agents", "Panels"],
        ["Chat", "Canvas"],
    ]

    var body: some View {
        let sections = Dictionary(uniqueKeysWithValues: ShortcutCatalog.sections.map { ($0.title, $0) })
        let customized = !app.settings.data.keyBindings.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts")
                        .font(Theme.ui(16, .medium))
                    Text("Click a shortcut to change it. Single keys work while the chat box doesn’t have the keyboard.")
                        .font(Theme.text(12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if customized {
                    Button("Reset all") {
                        app.recordingShortcut = nil
                        app.shortcutNote = nil
                        app.settings.data.keyBindings = [:]
                    }
                    .buttonStyle(.plain)
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
                Keycap("esc", size: 18)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Hairline()

            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Self.columns, id: \.self) { titles in
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(titles.compactMap { sections[$0] }) { section in
                                ShortcutSectionView(section: section)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }

            Hairline()

            Text(footnote)
                .font(Theme.text(12))
                .foregroundStyle(app.recordingShortcut == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                .lineLimit(1)
                .padding(.horizontal, 28)
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: 1040, maxHeight: 760)
        .fixedSize(horizontal: false, vertical: true)
        .glassPanel(cornerRadius: 28, frost: max(0.8, app.settings.data.panelFrost))
        // A click on empty space stops listening for a shortcut.
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture { app.recordingShortcut = nil }
        .animation(Motion.hover, value: customized)
        .animation(Motion.hover, value: footnote)
        .padding(40)
    }

    private var footnote: String {
        if app.recordingShortcut != nil {
            return "Press the new shortcut. Delete removes it; Esc cancels."
        }
        return app.shortcutNote ?? "Right-click a shortcut to add another key or reset it."
    }
}

private struct ShortcutSectionView: View {
    let section: ShortcutCatalog.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(Theme.ui(12, .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(section.rows) { row in
                ShortcutRowView(row: row)
            }
        }
    }
}

/// One shortcut: what it does on the left, its keys on the right.
private struct ShortcutRowView: View {
    let row: ShortcutCatalog.Row
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(Theme.text(13))
                .foregroundStyle(isFixed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            keys
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background {
            // The sheet's corner less the section's inset keeps the corners concentric.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering && !isFixed ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .contextMenu {
            if case let .commands(commands) = row.kind {
                ForEach(commands) { command in
                    let suffix = commands.count > 1 ? " for “\(command.title)”" : ""
                    Button("Add a Shortcut\(suffix)") { app.beginRecording(ShortcutSlot(command: command, index: nil)) }
                    Button("Reset to Default\(suffix)") {
                        app.recordingShortcut = nil
                        app.settings.keymap.reset(command)
                    }
                    .disabled(!app.keymap.isCustomized(command))
                }
            }
        }
    }

    private var isFixed: Bool {
        if case .fixed = row.kind { return true }
        return false
    }

    @ViewBuilder
    private var keys: some View {
        switch row.kind {
        case let .fixed(labels):
            HStack(spacing: 4) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    if label == "–" {
                        Text("–").font(Theme.text(12)).foregroundStyle(.tertiary)
                    } else {
                        Keycap(label, size: 20)
                    }
                }
            }
        case let .commands(commands):
            HStack(spacing: 4) {
                ForEach(commands) { command in
                    let chords = app.keymap.chords(for: command)
                    ForEach(Array(chords.enumerated()), id: \.offset) { index, chord in
                        ChordButton(label: chord.label, slot: ShortcutSlot(command: command, index: index))
                    }
                    // A command with no keys offers a slot; so does one that
                    // is listening for an extra key.
                    let adding = ShortcutSlot(command: command, index: nil)
                    if chords.isEmpty || app.recordingShortcut == adding {
                        ChordButton(label: nil, slot: adding)
                    }
                }
            }
        }
    }
}

/// A shortcut's keycap. Clicking it listens for a new chord to put in its place.
private struct ChordButton: View {
    /// The chord's label, or nil for a command with no keys yet.
    var label: String?
    var slot: ShortcutSlot
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let recording = app.recordingShortcut == slot
        Button {
            if recording {
                app.recordingShortcut = nil
            } else {
                app.beginRecording(slot)
            }
        } label: {
            Text(recording ? "Press keys" : (label ?? "None"))
                .font(Theme.mono(11, .medium))
                .foregroundStyle(
                    recording ? AnyShapeStyle(Theme.accent)
                        : (label == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(hovering ? .primary : .secondary))
                )
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(recording ? 0 : (hovering ? 0.14 : (scheme == .dark ? 0.10 : 0.055))))
                }
                .overlay {
                    if recording {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 1.5)
                    }
                }
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("Change this shortcut")
    }
}
