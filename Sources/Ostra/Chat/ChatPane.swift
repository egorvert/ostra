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
            // Another agent's content cross-fades in while the pane's
            // height morphs around it. The outer stack holds the old and new
            // content on top of each other while they fade.
            ZStack {
                ZStack {
                    Group {
                        switch tab {
                        case .chat: ChatTimeline(agent: agent)
                        case .activity: ActivityView(agent: agent)
                        case .diff: DiffView(agent: agent)
                        }
                    }
                    .id(tab)
                    .transition(.crossfade)
                }
                .id(agent.id)
                .transition(.crossfade)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(Rectangle())
        }
        .glassPanel(cornerRadius: Theme.panelRadius, frost: app.settings.data.chatFrost)
    }

    private func header(tab: ChatTab) -> some View {
        HStack(spacing: 8) {
            // What names the agent cross-fades with the content below. The
            // old and new sit on top of each other, so nothing shifts.
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    if StatusDot.isVisible(phase: agent.phase, unseen: false) {
                        StatusDot(phase: agent.phase, unseen: false, size: 8)
                    }

                    if app.rename?.agentID == agent.id {
                        RenameField()
                            .layoutPriority(1)
                    } else {
                        Text(agent.name)
                            .font(Theme.ui(14, .medium))
                            .lineLimit(1)
                            .layoutPriority(1)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { app.beginRename(agent.id) }
                            .help(app.help("Double-click to rename", .rename))
                    }

                    statusLine
                }
                .id(agent.id)
                .transition(.crossfade)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            if isPinned {
                QuietIconButton(symbol: "arrow.left.arrow.right", help: app.help("Swap sides", .swapSides)) { app.store.swapPinned() }
                QuietIconButton(symbol: "xmark", help: app.help("Close the split", .split)) {
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
                ContextRing(usage: usage)
            }
        }
        .font(Theme.mono(11))
        .lineLimit(1)
    }
}

/// How much of the model's context window the conversation uses, as a ring
/// that fills clockwise from the top. The number shows on hover.
struct ContextRing: View {
    var usage: Double
    var size: CGFloat = 12

    var body: some View {
        let fraction = min(max(usage, 0), 1)
        let full = fraction > 0.85
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle()
                // A sliver stays visible at 0%, so the ring reads as a gauge.
                .trim(from: 0, to: max(fraction, 0.03))
                .stroke(
                    full ? AnyShapeStyle(Theme.red) : AnyShapeStyle(.secondary),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .padding(4)
        .contentShape(Rectangle())
        .animation(Motion.snappy, value: fraction)
        .help("\(Int((fraction * 100).rounded()))% of the context window used")
        .accessibilityElement()
        .accessibilityLabel("Context window")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent used")
    }
}

/// The text field that edits an agent's name in place.
///
/// The field is exactly as wide as the name, so nothing beside it moves when
/// editing starts, and it grows and shrinks with the text as the user types.
/// Return commits and Esc cancels. A click anywhere else commits too, the way
/// renaming works in Finder.
struct RenameField: View {
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    /// The widest the field gets before the text scrolls inside it.
    var maxWidth: CGFloat = 240
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: Binding(
            get: { app.rename?.text ?? "" },
            set: { app.rename?.text = $0 }
        ))
        .textFieldStyle(.plain)
        .font(Theme.ui(size, weight))
        .focused($focused)
        .onSubmit { app.commitRename() }
        // A text field takes all the width it's offered, so give it the
        // width of its text and nothing more.
        .frame(width: width(of: app.rename?.text ?? ""))
        // The room for the insertion point borrows from the gap after the
        // name, so what follows doesn't shift when editing starts.
        .padding(.trailing, -Self.caretRoom)
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { app.commitRename() }
        }
    }

    /// The width `text` takes in the field's font, with room for the insertion point.
    private func width(of text: String) -> CGFloat {
        let measured = (text.isEmpty ? "Name" : text as NSString)
            .size(withAttributes: [.font: Fonts.nsSans(size, weight)])
            .width
        return min(max(measured.rounded(.up) + Self.caretRoom, 24), maxWidth)
    }

    private static let caretRoom: CGFloat = 4
}
