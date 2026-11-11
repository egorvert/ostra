import OstraCore
import SwiftUI

/// A menu whose every row shows the key that runs it.
struct KeyMenuView: View {
    let menu: KeyMenu
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(menu.title)
                .font(Theme.ui(11.5, .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 5)

            ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                KeyMenuRow(item: item, highlighted: app.menuHighlight == index)
                    .onHover { inside in
                        if inside, item.isEnabled { app.menuHighlight = index }
                    }
                    .onTapGesture {
                        if item.isEnabled { item.action() }
                    }
            }

            if let footer = menu.footer {
                Text(footer)
                    .font(Theme.text(11.5))
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
        HStack(spacing: 11) {
            Keycap(item.key.label, size: 20, prominent: highlighted && item.isEnabled)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .font(Theme.text(13.5))
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
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            case .shortcuts:
                backdrop
                ShortcutsView()
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            case let .confirmDelete(id):
                backdrop
                ConfirmDeleteView(agentID: id)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
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
                .font(Theme.ui(15, .medium))
            Text("The agent and its conversation go for good. Files it changed stay as they are.")
                .font(Theme.text(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Spacer()
                Button {
                    app.closeOverlay(animated: true)
                } label: {
                    HStack(spacing: 5) {
                        Text("Cancel").font(Theme.ui(12.5, .medium))
                        Text("esc").font(Theme.mono(10.5, .medium)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(height: 28)
                }
                .buttonStyle(.pressable)
                Button {
                    app.closeOverlay()
                    app.store.delete(agentID)
                    if app.store.selectedAgentID == nil { app.chatOpen = false }
                } label: {
                    HStack(spacing: 6) {
                        Text("Delete").font(Theme.ui(12.5, .medium))
                        Text("↩").font(Theme.mono(10.5, .medium)).opacity(0.7)
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

/// Every shortcut in one sheet.
struct ShortcutsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Shortcuts")
                .font(Theme.ui(17, .medium))

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 270, maximum: 400), spacing: 34, alignment: .top)],
                    alignment: .leading,
                    spacing: 26
                ) {
                    ForEach(ShortcutCatalog.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(Theme.ui(12, .medium))
                                .foregroundStyle(.tertiary)
                            ForEach(section.entries) { entry in
                                HStack(spacing: 10) {
                                    HStack(spacing: 3) {
                                        ForEach(Array(entry.keys.enumerated()), id: \.offset) { _, key in
                                            if key == "–" {
                                                Text("–").foregroundStyle(.tertiary)
                                            } else {
                                                Keycap(key, size: 19)
                                            }
                                        }
                                    }
                                    .frame(width: 92, alignment: .leading)
                                    Text(entry.title)
                                        .font(Theme.text(12.5))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: 1000, maxHeight: 640)
        .glassPanel(cornerRadius: 28, frost: max(0.55, app.settings.data.panelFrost))
        .padding(40)
    }
}
