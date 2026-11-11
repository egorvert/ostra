import OstraCore
import SwiftUI

/// One agent's pane: a status line, three views, and the chosen view.
struct ChatPane: View {
    let agent: AgentModel
    /// True for the second column of a split.
    var isPinned = false

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The pinned column always shows its conversation.
        let tab = isPinned ? ChatTab.chat : app.chatTab
        VStack(spacing: 0) {
            header(tab: tab)
            Hairline()
            ZStack {
                Group {
                    switch tab {
                    case .chat: ChatTimeline(agent: agent)
                    case .activity: ActivityView(agent: agent)
                    case .diff: DiffView(agent: agent)
                    }
                }
                .id(tab)
                .transition(.swap(forward: app.chatTabForward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(Rectangle())
            // Swapping agents with the keyboard happens all day, so the
            // content changes at once. Only a change of tab animates.
            .id(agent.id)
            .transaction(value: agent.id) { $0.animation = nil }
        }
        .glassPanel(cornerRadius: Theme.panelRadius, frost: app.settings.data.chatFrost)
    }

    private func header(tab: ChatTab) -> some View {
        HStack(spacing: 8) {
            if StatusDot.isVisible(phase: agent.phase, unseen: false) {
                StatusDot(phase: agent.phase, unseen: false, size: 8)
            }

            if app.rename?.agentID == agent.id, app.rename?.site == .header, !isPinned {
                RenameField(font: Theme.ui(14, .medium))
                    .frame(maxWidth: 180)
                    .layoutPriority(1)
            } else {
                Text(agent.name)
                    .font(Theme.ui(14, .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { app.beginRename(agent.id, site: .header) }
                    .help("Double-click to rename (R)")
            }

            statusLine

            Spacer(minLength: 12)

            if isPinned {
                QuietIconButton(symbol: "arrow.left.arrow.right", help: "Swap sides (|)") { app.store.swapPinned() }
                QuietIconButton(symbol: "xmark", help: "Close the split (\\)") {
                    Motion.perform(Motion.panelOut) { app.store.pin(nil) }
                }
            } else {
                TextTabs(
                    items: ChatTab.allCases,
                    selection: tab,
                    label: \.label,
                    hint: { app.hint(for: $0) }
                ) { app.setChatTab($0) }
                QuietIconButton(symbol: "xmark", help: "Close (esc)") { app.toggleChat() }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 9)
        .frame(height: Theme.headerHeight)
    }

    /// The small status line from the sketch: branch, line counts, and context use.
    private var statusLine: some View {
        HStack(spacing: 8) {
            if let branch = agent.snapshot.branch, !branch.isEmpty {
                Text(branch)
                    .foregroundStyle(.tertiary)
            }
            if !agent.changes.isEmpty {
                HStack(spacing: 5) {
                    Text("+\(agent.changes.additions)")
                        .foregroundStyle(Theme.addition(scheme))
                    Text("−\(agent.changes.deletions)")
                        .foregroundStyle(Theme.deletion(scheme))
                }
            }
            if let usage = agent.conversation.meta.contextUsage {
                Text("\(Int((usage * 100).rounded()))%")
                    .foregroundStyle(usage > 0.85 ? AnyShapeStyle(Theme.red) : AnyShapeStyle(.tertiary))
                    .help("Context window in use")
            }
        }
        .font(Theme.mono(11))
        .lineLimit(1)
    }
}

/// The text field that edits an agent's name in place.
///
/// Return commits and Esc cancels. A click anywhere else commits too, the way
/// renaming works in Finder.
struct RenameField: View {
    var font: Font
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: Binding(
            get: { app.rename?.text ?? "" },
            set: { app.rename?.text = $0 }
        ))
        .textFieldStyle(.plain)
        .font(font)
        .focused($focused)
        .onSubmit { app.commitRename() }
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { app.commitRename() }
        }
    }
}
