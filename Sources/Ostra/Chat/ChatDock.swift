import AppKit
import OstraCore
import SwiftUI

/// The center of the HUD: the chat pane, any pending request, and the chat box.
///
/// The pieces share one glass container, so they blend where they meet and
/// the pane grows out of the chat box when it opens.
struct ChatDock: View {
    /// The widest the dock can be in the current window.
    var availableWidth: CGFloat

    @Environment(AppModel.self) private var app
    @State private var inputHeight: CGFloat = 46
    @State private var requestHeight: CGFloat = 0

    var body: some View {
        let agent = app.store.selectedAgent
        let pinned = app.store.pinnedAgent
        let showPane = app.chatOpen && agent != nil
        let hasRequest = agent?.snapshot.pendingRequest != nil
        // The pane gives up height when a request bar needs room, so the dock
        // never grows into the band where the selected card sits.
        let paneHeight = max(170, min(
            app.chatPaneHeight,
            app.dockMaxHeight - inputHeight - 10 - (hasRequest ? requestHeight + 10 : 0)
        ))
        let split = showPane && pinned != nil
        let columnWidth = split
            ? min(Theme.chatWidth, max(Theme.chatMinWidth, (availableWidth - 10) / 2))
            : min(Theme.chatWidth, availableWidth)
        let width = split ? min(columnWidth * 2 + 10, availableWidth) : columnWidth

        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                if showPane, let agent {
                    HStack(spacing: 10) {
                        ChatPane(agent: agent)
                        if let pinned {
                            ChatPane(agent: pinned, isPinned: true)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .frame(height: paneHeight)
                    .transition(.rise)
                }

                if let agent, let request = agent.snapshot.pendingRequest {
                    Group {
                        if agent.phase == .awaitingInput {
                            QuestionBar(agent: agent, request: request)
                        } else {
                            ApprovalBar(agent: agent, request: request)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { requestHeight = $0 }
                    .transition(.pop(from: .bottom))
                }

                InputBar()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputHeight = $0 }
            }
            .frame(width: width)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            app.hudRegions.set("chat", frame)
            app.dockFrameChanged()
        }
        .onDisappear { app.hudRegions.set("chat", nil) }
    }
}

/// The chat box. It talks to the selected agent, or starts a new one when nothing is selected.
struct InputBar: View {
    @Environment(AppModel.self) private var app
    @State private var height: CGFloat = 18

    var body: some View {
        @Bindable var app = app
        let agent = app.store.selectedAgent

        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if app.draft.isEmpty {
                    Text(placeholder(agent))
                        .font(Theme.text(14))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                ChatTextView(
                    text: $app.draft,
                    height: $height,
                    font: Fonts.nsSans(14),
                    onSubmit: { app.submitDraft() },
                    onFocusChange: { focused in
                        Motion.instantly { app.isTyping = focused }
                    },
                    register: { app.focus.chatInput = $0 }
                )
                .frame(height: height)
            }
            .padding(.vertical, 5)

            trailing(agent)
                .frame(width: 28, height: 28)
        }
        .padding(.leading, 20)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .glassPanel(cornerRadius: Theme.inputRadius, frost: app.settings.data.chatFrost * 0.85)
        .overlay(alignment: .top) { focusGlow }
        .contentShape(RoundedRectangle(cornerRadius: Theme.inputRadius, style: .continuous))
        .onTapGesture { app.focusInput() }
    }

    private var canSend: Bool {
        !app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func placeholder(_ agent: AgentModel?) -> String {
        if let agent {
            return agent.phase == .awaitingInput ? "Answer \(agent.name)" : "Message \(agent.name)"
        }
        if let project = app.store.currentProject { return "New agent in \(project.title)" }
        return "Press A to add a project"
    }

    /// One control at a time: send when there's text, stop while the agent
    /// runs, and otherwise a quiet Return glyph that says how to start typing.
    @ViewBuilder
    private func trailing(_ agent: AgentModel?) -> some View {
        if canSend {
            Button {
                app.submitDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.pressable)
            .help("Send (↩)")
        } else if let agent, agent.phase.isActive {
            Button {
                app.store.interrupt(agent.id)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.pressable)
            .help("Stop \(agent.name) (X)")
        } else if !app.isTyping {
            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.quaternary)
                .help("Press Return to type")
        }
    }

    /// A soft light on the box's top edge while it has the keyboard, as in the sketch.
    private var focusGlow: some View {
        Capsule()
            .fill(Theme.accent.opacity(app.isTyping ? 0.5 : 0))
            .frame(height: 2)
            .padding(.horizontal, 34)
            .blur(radius: 2)
            .offset(y: -1)
            .allowsHitTesting(false)
    }
}

/// An approval request, with the keys that answer it.
struct ApprovalBar: View {
    let agent: AgentModel
    let request: PendingRequest
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(agent.name) wants to \(verb)")
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(.secondary)
                if let prompt = request.prompt {
                    Text(LiveLine.shortCommand(prompt))
                        .font(Theme.mono(12))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                quiet("Deny", key: app.isTyping ? "⌘⌫" : "N") { app.store.respond(.decline, to: agent.id) }
                quiet("Always", key: app.isTyping ? "⌘⇧↩" : "⇧Y") { app.store.respond(.acceptForSession, to: agent.id) }
                Button {
                    app.store.respond(.accept, to: agent.id)
                } label: {
                    HStack(spacing: 6) {
                        Text("Allow").font(Theme.ui(12.5, .medium))
                        Text(app.isTyping ? "⌘↩" : "Y").font(Theme.mono(10.5, .medium)).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(Theme.accent))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 20, frost: max(app.settings.data.chatFrost, 0.35))
    }

    private var verb: String {
        switch request.kind {
        case .command: "run"
        case .fileChange: "change files"
        case .fileRead: "read a file"
        case .permission, .other, .userInput: "continue"
        }
    }

    private func quiet(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(Theme.ui(12.5, .medium))
                Text(key).font(Theme.mono(10.5, .medium)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary.opacity(0.8))
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// A question from the agent. Number keys pick a choice; the chat box takes free text.
struct QuestionBar: View {
    let agent: AgentModel
    let request: PendingRequest
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(request.questions.prefix(1)) { question in
                Text(question.prompt)
                    .font(Theme.ui(13, .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                if !question.choices.isEmpty {
                    VStack(spacing: 1) {
                        ForEach(Array(question.choices.prefix(9).enumerated()), id: \.offset) { index, choice in
                            ChoiceRow(index: index, choice: choice) { app.chooseAnswer(index) }
                        }
                    }
                }
            }
            if request.questions.count > 1 {
                Text("\(request.questions.count - 1) more to answer after this.")
                    .font(Theme.text(11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20, frost: max(app.settings.data.chatFrost, 0.35))
    }
}

private struct ChoiceRow: View {
    var index: Int
    var choice: PendingRequest.Question.Choice
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(choice.label)
                    .font(Theme.text(13))
                if let detail = choice.detail {
                    Text(detail)
                        .font(Theme.text(12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}
