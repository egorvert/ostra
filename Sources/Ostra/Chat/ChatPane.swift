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
            Group {
                switch tab {
                case .chat: ChatTimeline(agent: agent)
                case .activity: ActivityView(agent: agent)
                case .diff: DiffView(agent: agent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Swapping agents with the keyboard happens all day, so the
            // content changes at once instead of cross-fading.
            .id(agent.id)
            .transaction { $0.animation = nil }
        }
        .glassPanel(cornerRadius: Theme.panelRadius, frost: app.settings.data.chatFrost)
    }

    private func header(tab: ChatTab) -> some View {
        HStack(spacing: 10) {
            StatusDot(phase: agent.phase, unseen: false, size: 8)

            Text(agent.name)
                .font(Theme.ui(13.5, .medium))
                .lineLimit(1)
                .layoutPriority(1)

            statusLine

            Spacer(minLength: 12)

            if isPinned {
                QuietIconButton(symbol: "arrow.left.arrow.right", help: "Swap sides (|)") { app.store.swapPinned() }
                QuietIconButton(symbol: "xmark", help: "Close the split (\\)") { app.store.pin(nil) }
            } else {
                TextTabs(items: ChatTab.allCases, selection: tab, label: \.label) { app.setChatTab($0) }
                QuietIconButton(symbol: "xmark", help: "Close (esc)") { app.toggleChat(animated: true) }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    /// The small status line from the sketch: branch, line counts, and context use.
    private var statusLine: some View {
        HStack(spacing: 7) {
            if let branch = agent.snapshot.branch, !branch.isEmpty {
                Text(branch)
                    .foregroundStyle(.tertiary)
            }
            if !agent.changes.isEmpty {
                Text("+\(agent.changes.additions)")
                    .foregroundStyle(Theme.addition(scheme).opacity(0.9))
                Text("−\(agent.changes.deletions)")
                    .foregroundStyle(Theme.deletion(scheme).opacity(0.9))
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
