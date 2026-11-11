import AppKit
import OstraCore
import SwiftUI

/// An agent on the canvas: a glass tile with a name, one line, and a status
/// dot on the corner.
///
/// The tile is Liquid Glass, so it shows over any background, and its ink
/// follows the brightness of the canvas behind it.
struct AgentCardView: View {
    let agent: AgentModel
    /// The screen point of the world's origin inside the world layer.
    let origin: CGPoint

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGPoint?

    private var isSelected: Bool { app.store.selectedAgentID == agent.id }
    private var isPinned: Bool { app.store.pinnedAgentID == agent.id }
    private var isDragging: Bool { app.draggingAgentID == agent.id }
    private var isRenaming: Bool { app.rename?.agentID == agent.id && app.rename?.site == .card }

    var body: some View {
        let size = CanvasLayout.cardSize

        CardFace(agent: agent, hidesName: isRenaming)
            .adaptiveTone(over: app.toneFrame(forWorld: CanvasLayout.footprintRect(at: agent.position)))
            .frame(width: size.width, height: size.height)
            .scaleEffect(isDragging ? 1.04 : 1)
            .animation(reduceMotion ? nil : (isDragging ? Motion.snappy : Motion.settle), value: isDragging)
            .position(x: origin.x + agent.position.x, y: origin.y + agent.position.y)
            .zIndex(isDragging ? 3 : (isSelected ? 2 : 1))
            .gesture(dragGesture)
            .onTapGesture {
                app.closeOverlay()
                // The second click of a double-click renames the agent.
                if NSApp.currentEvent?.clickCount == 2 {
                    app.beginRename(agent.id, site: .card)
                } else {
                    app.select(agent.id, openChat: true)
                }
            }
            .contextMenu {
                Button("Rename") { app.beginRename(agent.id, site: .card) }
                if agent.phase.isActive {
                    Button("Stop") { app.store.interrupt(agent.id) }
                }
                Divider()
                Button("Archive") { app.archive(agent.id) }
                Button("Delete…") { app.open(.confirmDelete(agent.id), animated: true) }
            }
            .help(agent.title)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(agent.name), \(agent.title), \(agent.phase.label)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? agent.position
                if dragStart == nil {
                    dragStart = start
                    app.draggingAgentID = agent.id
                }
                let zoom = app.zoom
                // The card stays under the pointer, at the offset it was grabbed.
                Motion.instantly {
                    app.store.move(agent.id, to: CGPoint(
                        x: start.x + value.translation.width / zoom,
                        y: start.y + value.translation.height / zoom
                    ))
                }
            }
            .onEnded { _ in
                dragStart = nil
                app.draggingAgentID = nil
            }
    }
}

/// What the card shows. It lives apart from the card's gestures, so the
/// adaptive color scheme reaches the glass and the text together.
private struct CardFace: View {
    let agent: AgentModel
    var hidesName: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 2) {
            Text(agent.name)
                .font(Theme.ui(14, .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .opacity(hidesName ? 0 : 1)
            Text(line)
                .font(Theme.text(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: shape)
        .contentShape(shape)
    }

    /// One line: what the agent is doing while it's active, and its task otherwise.
    private var line: String {
        agent.phase.isActive || agent.phase == .failed ? agent.liveLine : agent.title
    }
}

/// What sits on top of a card: the selection ring and the status dot.
///
/// A glass container draws its glass above everything else inside it, so
/// these live in a layer of their own over the cards.
struct AgentCardAdornment: View {
    let agent: AgentModel
    let origin: CGPoint

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = CanvasLayout.cardSize
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        let isSelected = app.store.selectedAgentID == agent.id
        let isPinned = app.store.pinnedAgentID == agent.id
        let isDragging = app.draggingAgentID == agent.id

        ZStack(alignment: .topTrailing) {
            if isSelected {
                shape.strokeBorder(Theme.accent, lineWidth: 2)
            } else if isPinned {
                shape.strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
            }
            // The dot's center sits on the card's outline, at the middle of
            // the corner arc, the way the wireframe draws it.
            let inset = Theme.cardRadius * (1 - 0.7071)
            StatusDot(phase: agent.phase, unseen: agent.snapshot.hasUnseenResult, size: 11, ringed: true)
                .offset(x: 5.5 - inset, y: inset - 5.5)
        }
        .frame(width: size.width, height: size.height, alignment: .topTrailing)
        .adaptiveTone(over: app.toneFrame(forWorld: CanvasLayout.footprintRect(at: agent.position)))
        .scaleEffect(isDragging ? 1.04 : 1)
        .animation(reduceMotion ? nil : (isDragging ? Motion.snappy : Motion.settle), value: isDragging)
        .position(x: origin.x + agent.position.x, y: origin.y + agent.position.y)
        .zIndex(isDragging ? 3 : (isSelected ? 2 : 1))
        .allowsHitTesting(false)
    }
}

/// A small dot that shows an agent's state.
///
/// - Grey, breathing: at work.
/// - Amber: waits for you.
/// - Green: finished, and you haven't looked yet.
/// - Red: failed.
/// - No dot: resting.
struct StatusDot: View {
    var phase: AgentPhase
    var unseen: Bool
    var size: CGFloat = 10
    /// Draws a thin rim in the surface's own tone, so the dot stays crisp
    /// where it crosses a card's edge.
    var ringed = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var color: Color? { Self.color(phase: phase, unseen: unseen) }

    static func color(phase: AgentPhase, unseen: Bool) -> Color? {
        switch phase {
        case .starting, .working: Theme.neutral
        case .awaitingApproval, .awaitingInput: Theme.amber
        case .failed: Theme.red
        case .done: unseen ? Theme.green : nil
        case .idle, .interrupted: nil
        }
    }

    /// True when the state has a dot. Resting agents have none.
    static func isVisible(phase: AgentPhase, unseen: Bool) -> Bool {
        color(phase: phase, unseen: unseen) != nil
    }

    var body: some View {
        Group {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(phase.isRunning && breathing ? 0.4 : 1)
                    .background {
                        if ringed {
                            Circle()
                                .fill(scheme == .dark ? Color(white: 0.12) : Color.white)
                                .padding(-1.5)
                        }
                    }
            } else {
                Color.clear.frame(width: size, height: size)
            }
        }
        .onAppear { breathe() }
        .onChange(of: phase) { _, _ in breathe() }
        .accessibilityLabel(phase.label)
    }

    private func breathe() {
        breathing = false
        guard phase.isRunning, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

/// Three dots that take turns lighting up, for an agent at work.
struct TypingDots: View {
    var dot: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: dot * 0.75) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: dot, height: dot)
                    .opacity(animating ? 1 : 0.28)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.55).repeatForever().delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

/// A project's group: a clear glass region behind its agents, with the folder name on top.
struct ProjectGroupView: View {
    let project: Project
    let origin: CGPoint

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragLast: CGSize = .zero

    var body: some View {
        let frame = app.store.groupFrame(for: project.id)
        let isCurrent = app.store.currentProject?.id == project.id
        let isEmpty = app.store.agents(in: project.id).isEmpty

        GroupFace(title: project.title, isCurrent: isCurrent, isEmpty: isEmpty) { translation in
            guard let translation else {
                dragLast = .zero
                return
            }
            let zoom = app.zoom
            let delta = CGVector(
                dx: (translation.width - dragLast.width) / zoom,
                dy: (translation.height - dragLast.height) / zoom
            )
            dragLast = translation
            Motion.instantly { app.store.moveGroup(project.id, by: delta) }
        } onChoose: {
            app.store.currentProjectID = project.id
        }
        // The label decides the ink: it's the only text on the region.
        .adaptiveTone(over: app.toneFrame(
            forWorld: CGRect(x: frame.minX, y: frame.minY, width: min(frame.width, 260), height: 56)
        ))
        .frame(width: frame.width, height: frame.height)
        .position(x: origin.x + frame.midX, y: origin.y + frame.midY)
        // The region settles with a spring when membership changes, but
        // tracks the pointer exactly while a card is dragged.
        .animation(app.draggingAgentID == nil && !reduceMotion ? Motion.settle : nil, value: frame)
    }
}

private struct GroupFace: View {
    var title: String
    var isCurrent: Bool
    var isEmpty: Bool
    /// Reports the drag translation while the label moves, then nil when the drag ends.
    var onDrag: (CGSize?) -> Void
    var onChoose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.groupRadius, style: .continuous)

        ZStack {
            // The region is decoration: clicks and drags inside a group reach the canvas.
            Color.clear
                .glassEffect(.clear, in: shape)
                .allowsHitTesting(false)
            if isEmpty {
                Text("No agents")
                    .font(Theme.text(12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(title)
                .font(Theme.ui(12, .medium))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture(perform: onChoose)
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { onDrag($0.translation) }
                        .onEnded { _ in onDrag(nil) }
                )
                .help("New agents start in the highlighted project. Click to choose this one; drag to move the group.")
                .padding(.top, 14)
                .padding(.leading, 16)
        }
    }
}
