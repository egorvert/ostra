import OstraCore
import SwiftUI

/// Everything that floats over the canvas.
///
/// At rest the HUD is three things: the chat box, one button in the
/// bottom-left corner, and one in the bottom-right. Everything else appears
/// when it's needed and leaves when it isn't.
struct HUDLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geometry in
            let margin = Theme.hudMargin
            let panelInset = app.workspaceOpen ? app.workspaceWidth + margin : 0
            // Keep the dock clear of the corner buttons.
            let corner = Theme.cornerButton + margin
            let dockWidth = max(Theme.chatMinWidth - 80, geometry.size.width - panelInset - (margin + corner) * 2)

            ZStack {
                if app.workspaceOpen {
                    WorkspacePanel()
                        .frame(width: app.workspaceWidth)
                        .padding(.leading, margin)
                        .padding(.top, 44)
                        .padding(.bottom, margin + Theme.cornerButton + 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .transition(.slide(from: .leading))
                }

                CornerButton(symbol: "chevron.left.forwardslash.chevron.right", shape: .circle, active: app.workspaceOpen, help: "Workspace: diff, files, terminal, activity (C)") {
                    app.toggleWorkspace()
                }
                .hudRegion("workspace-button", in: app.hudRegions)
                .padding(margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                ChatDock(availableWidth: dockWidth)
                    .padding(.bottom, margin)
                    .padding(.leading, panelInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                MenuCorner()
                    .padding(margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                Notices()
                    .padding(.top, 14)
                    .padding(.leading, panelInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if app.statusPaneOpen {
                    StatusPane()
                        .padding(.top, 44)
                        .padding(.trailing, margin)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.slide(from: .trailing, distance: 24))
                }

                ModalLayer()
            }
        }
    }
}

/// A single glass button that sits in a corner of the window.
private struct CornerButton: View {
    enum Outline {
        case circle
        case square
    }

    var symbol: String
    var shape: Outline
    var active: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        let size = Theme.cornerButton
        let label = Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary.opacity(0.7)))
            .frame(width: size, height: size)

        Button(action: action) {
            switch shape {
            case .circle:
                label.contentShape(Circle())
            case .square:
                label.contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .buttonStyle(.pressable)
        .modifier(CornerGlass(shape: shape))
        .help(help)
    }
}

private struct CornerGlass: ViewModifier {
    var shape: CornerButton.Outline

    func body(content: Content) -> some View {
        switch shape {
        case .circle: content.glassEffect(.regular.interactive(), in: Circle())
        case .square: content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// The bottom-right corner: the menu button, and whichever menu is open above it.
private struct MenuCorner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .trailing, spacing: 10) {
                switch app.overlay {
                case let .menu(id):
                    KeyMenuView(menu: app.menu(for: id))
                        .transition(.pop(from: .bottomTrailing))
                case .picker:
                    AgentPickerView()
                        .transition(.pop(from: .bottomTrailing))
                default:
                    EmptyView()
                }

                CornerButton(symbol: "line.3.horizontal", shape: .square, active: isMenuOpen, help: "Menu (M)") {
                    app.toggleMenu(.main, animated: true)
                }
            }
        }
        .hudRegion("menu", in: app.hudRegions)
    }

    private var isMenuOpen: Bool {
        switch app.overlay {
        case .menu, .picker: true
        default: false
        }
    }
}

/// The top of the window: the engine's status and short-lived messages.
private struct Notices: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 8) {
            if !app.store.connection.isReady {
                ConnectionBanner(state: app.store.connection)
                    .transition(.pop(from: .top))
            }
            if let hint = app.hint {
                Text(hint)
                    .font(Theme.ui(12, .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .glassCapsule(frost: 0.3)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            ForEach(app.store.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.asymmetric(
                        insertion: .offset(y: -8).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                    ))
            }
        }
        .animation(Motion.snappy, value: app.store.toasts.map(\.id))
        .animation(Motion.snappy, value: app.store.connection)
        .animation(Motion.easeOut(0.15), value: app.hint)
    }
}

private struct ConnectionBanner: View {
    var state: ConnectionState

    var body: some View {
        HStack(spacing: 9) {
            switch state {
            case .failed:
                Circle().fill(Theme.red).frame(width: 7, height: 7)
            case let .preparing(_, progress?):
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            default:
                ProgressView().controlSize(.small)
            }
            Text(message)
                .font(Theme.ui(12, .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .glassCapsule(frost: 0.35)
    }

    private var message: String {
        switch state {
        case .idle, .starting: "Starting the engine"
        case let .preparing(message, progress):
            progress.map { "\(message) \(Int($0 * 100))%" } ?? message
        case .connecting: "Connecting"
        case .ready: "Connected"
        case let .reconnecting(attempt): "Reconnecting, attempt \(attempt)"
        case let .failed(message): message
        }
    }
}

private struct ToastView: View {
    var toast: Toast
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            if toast.kind == .error {
                Circle().fill(Theme.red).frame(width: 7, height: 7)
            }
            Text(toast.text)
                .font(Theme.ui(12, .medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let label = toast.actionLabel {
                Button {
                    app.store.performToastAction(toast.id)
                } label: {
                    HStack(spacing: 5) {
                        Text(label).font(Theme.ui(12, .medium))
                        Text("Z").font(Theme.mono(10, .medium)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .frame(maxWidth: 440)
        .glassCapsule(frost: 0.35)
        .onTapGesture { app.store.dismissToast(toast.id) }
    }
}

/// A standing list of the agents that want the user and the agents at work.
private struct StatusPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let store = app.store
        let waiting = store.canvasOrder.filter(\.needsAttention)
        let working = store.canvasOrder.filter { $0.phase.isRunning }
        let resting = store.canvasOrder.filter { !$0.needsAttention && !$0.phase.isRunning }

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Needs you", waiting)
                section("Working", working)
                section("Resting", resting)
                if store.agents.isEmpty {
                    Text("No agents yet")
                        .font(Theme.text(12))
                        .foregroundStyle(.tertiary)
                        .padding(8)
                }
            }
            .padding(10)
        }
        .frame(width: 270)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .glassPanel(cornerRadius: 24, frost: app.settings.data.panelFrost)
        .hudRegion("status", in: app.hudRegions)
    }

    @ViewBuilder
    private func section(_ title: String, _ agents: [AgentModel]) -> some View {
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(title)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                ForEach(agents) { agent in
                    AgentRow(agent: agent, highlighted: app.store.selectedAgentID == agent.id)
                        .onTapGesture { app.select(agent.id, openChat: true) }
                }
            }
        }
    }
}

/// An agent in a list: its status dot, name, and one line.
struct AgentRow: View {
    let agent: AgentModel
    var highlighted = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(phase: agent.phase, unseen: agent.snapshot.hasUnseenResult, size: 8)
                .frame(width: 8)
            Text(agent.name)
                .font(Theme.ui(13, .medium))
            Text(agent.phase.isActive || agent.phase == .failed ? agent.liveLine : agent.title)
                .font(Theme.text(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(highlighted ? 0.08 : (hovering ? 0.045 : 0)))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
