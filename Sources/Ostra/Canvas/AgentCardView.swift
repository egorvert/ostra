import OstraCore
import SwiftUI

/// An agent on the canvas: a name, one line, and a status dot on the corner.
///
/// Cards are content, so they stay plain. Glass belongs to the controls that
/// float above the canvas.
struct AgentCardView: View {
    let agent: AgentModel
    /// The screen point of the world's origin inside the world layer.
    let origin: CGPoint

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dragStart: CGPoint?

    private var isSelected: Bool { app.store.selectedAgentID == agent.id }
    private var isPinned: Bool { app.store.pinnedAgentID == agent.id }
    private var isDragging: Bool { app.draggingAgentID == agent.id }

    var body: some View {
        let size = CanvasLayout.cardSize
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 3) {
            Text(agent.name)
                .font(Theme.ui(14, .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(line)
                .font(Theme.text(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 15)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background {
            if app.settings.data.glassCards {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(Theme.cardFill(scheme))
            }
        }
        .overlay {
            shape.strokeBorder(
                isSelected ? Theme.accent : Theme.cardStroke(scheme),
                lineWidth: isSelected ? 2 : (isPinned ? 1.5 : 1)
            )
        }
        .overlay {
            if isPinned, !isSelected {
                shape.strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            StatusDot(phase: agent.phase, unseen: agent.snapshot.hasUnseenResult, ringed: true)
                .offset(x: 3, y: -3)
        }
        .shadow(
            color: .black.opacity(isDragging ? 0.16 : (hovering ? 0.08 : 0.035)),
            radius: isDragging ? 18 : (hovering ? 10 : 4),
            y: isDragging ? 10 : (hovering ? 4 : 1)
        )
        .scaleEffect(isDragging ? 1.03 : 1)
        .animation(reduceMotion ? nil : Motion.snappy, value: isDragging)
        .animation(reduceMotion ? nil : Motion.hover, value: hovering)
        .position(x: origin.x + agent.position.x, y: origin.y + agent.position.y)
        .zIndex(isDragging ? 3 : (isSelected ? 2 : 1))
        .onHover { hovering = $0 }
        .gesture(dragGesture)
        .onTapGesture {
            app.closeOverlay()
            app.select(agent.id, openChat: true)
        }
        .help(agent.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(agent.title), \(agent.phase.label)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// One line: what the agent is doing while it's active, and its task otherwise.
    private var line: String {
        agent.phase.isActive || agent.phase == .failed ? agent.liveLine : agent.title
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
    /// Draws a ring in the canvas color, so the dot reads when it overlaps a card's edge.
    var ringed = false

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var color: Color? {
        switch phase {
        case .starting, .working: Theme.neutral
        case .awaitingApproval, .awaitingInput: Theme.amber
        case .failed: Theme.red
        case .done: unseen ? Theme.green : nil
        case .idle, .interrupted: nil
        }
    }

    var body: some View {
        Group {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(phase.isRunning && breathing ? 0.35 : 1)
                    .background {
                        if ringed {
                            Circle()
                                .fill(app.settings.data.canvasColor.flatMap(Color.init(hex:)) ?? Theme.canvasBase(scheme))
                                .padding(-2.5)
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

/// A project's group: a quiet region behind its agents, with the folder name on top.
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
        let showsRegion = app.store.projects.count > 1 || isEmpty
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        ZStack {
            if showsRegion {
                shape.fill(Color.primary.opacity(0.022))
                shape.strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
            }
            if isEmpty {
                Text("No agents")
                    .font(Theme.text(12))
                    .foregroundStyle(.tertiary)
            }
        }
        // The region is decoration: clicks and drags inside a group reach the canvas.
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
            label(isCurrent: isCurrent)
                .padding(.top, 13)
                .padding(.leading, 18)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: origin.x + frame.midX, y: origin.y + frame.midY)
        // The region settles with a spring when membership changes, but
        // tracks the pointer exactly while a card is dragged.
        .animation(app.draggingAgentID == nil && !reduceMotion ? Motion.settle : nil, value: frame)
    }

    private func label(isCurrent: Bool) -> some View {
        Text(project.title)
            .font(Theme.ui(11.5, .medium))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { app.store.currentProjectID = project.id }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        let zoom = app.zoom
                        let delta = CGVector(
                            dx: (value.translation.width - dragLast.width) / zoom,
                            dy: (value.translation.height - dragLast.height) / zoom
                        )
                        dragLast = value.translation
                        Motion.instantly { app.store.moveGroup(project.id, by: delta) }
                    }
                    .onEnded { _ in dragLast = .zero }
            )
            .help("New agents start in the highlighted project. Click to choose this one; drag to move the group.")
    }
}
