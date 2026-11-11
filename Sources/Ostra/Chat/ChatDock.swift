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
    /// False for a moment after the agent changes, so a new agent's pane
    /// appears at its size instead of growing into it.
    @State private var heightAnimates = true

    var body: some View {
        let agent = app.store.selectedAgent
        let pinned = app.store.pinnedAgent
        let showPane = app.chatOpen && agent != nil
        let hasRequest = agent?.snapshot.pendingRequest != nil
        // The pane gives up height when a request bar needs room, so the dock
        // never grows into the band where the selected card sits.
        let tallest = max(170, min(
            app.chatPaneHeight,
            app.dockMaxHeight - inputHeight - 10 - (hasRequest ? requestHeight + 10 : 0)
        ))
        // A short conversation gets a short pane; the pane grows with it.
        let paneHeight = min(tallest, max(wantedHeight(agent, tab: app.chatTab), wantedHeight(pinned, tab: .chat)))
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
                    .animation(heightAnimates ? Motion.snappy : nil, value: paneHeight)
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

                PromptInput()
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
        .onChange(of: app.store.selectedAgentID) { _, _ in
            heightAnimates = false
            Task {
                try? await Task.sleep(for: .milliseconds(320))
                heightAnimates = true
            }
        }
    }

    /// The pane height an agent's current view asks for.
    private func wantedHeight(_ agent: AgentModel?, tab: ChatTab) -> CGFloat {
        guard let agent else { return 0 }
        // Activity and Diff are reference views, so they take the full height.
        guard tab == .chat else { return .infinity }
        let header: CGFloat = 45
        guard agent.conversation.isLoaded, let content = app.conversationHeights[agent.id] else {
            return header + 130
        }
        return header + max(content, 110)
    }
}

/// The chat box.
///
/// At rest it's one quiet line. With the keyboard, it grows a footer: what the
/// message goes to on the left, and one button on the right that sends, or
/// stops the agent while it runs. With no agent selected, the message starts
/// a new agent, and the footer chooses its project, model, and permissions.
struct PromptInput: View {
    @Environment(AppModel.self) private var app
    @State private var height: CGFloat = 18

    var body: some View {
        @Bindable var app = app
        let agent = app.store.selectedAgent
        let expanded = app.isTyping || canSend

        VStack(alignment: .leading, spacing: 8) {
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

                if !expanded {
                    restingControl(agent)
                        .frame(width: 28, height: 28)
                }
            }

            if expanded {
                HStack(spacing: 14) {
                    tools(agent)
                    Spacer(minLength: 8)
                    submitButton(agent)
                }
                .frame(height: 28)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, expanded ? 10 : 9)
        .padding(.top, 9)
        .padding(.bottom, expanded ? 10 : 9)
        .glassPanel(cornerRadius: Theme.inputRadius, frost: app.settings.data.chatFrost * 0.85)
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

    /// While the box is at rest: stop if the agent runs, else a hint that Return starts typing.
    @ViewBuilder
    private func restingControl(_ agent: AgentModel?) -> some View {
        if let agent, agent.phase.isActive {
            stopButton(agent)
        } else {
            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.quaternary)
                .help("Press Return to type")
        }
    }

    @ViewBuilder
    private func submitButton(_ agent: AgentModel?) -> some View {
        if !canSend, let agent, agent.phase.isActive {
            stopButton(agent)
        } else {
            Button {
                app.submitDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.06))))
            }
            .buttonStyle(.pressable)
            .disabled(!canSend)
            .help("Send (↩)")
        }
    }

    private func stopButton(_ agent: AgentModel) -> some View {
        Button {
            app.store.interrupt(agent.id)
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.pressable)
        .help("Stop \(agent.name) (X)")
    }

    /// What the message goes to: the agent's model and permissions, or the
    /// project, model, and permissions for a new agent.
    @ViewBuilder
    private func tools(_ agent: AgentModel?) -> some View {
        let store = app.store
        if let agent {
            Text(modelName(agent))
                .font(Theme.ui(12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Menu {
                ForEach(RuntimeMode.allCases) { mode in
                    Button {
                        store.setRuntimeMode(mode, for: agent.id)
                    } label: {
                        if agent.snapshot.runtimeMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                toolLabel(agent.snapshot.runtimeMode.label)
            }
            .modifier(QuietMenu())
        } else {
            Menu {
                ForEach(store.projects) { project in
                    Button(project.title) { store.currentProjectID = project.id }
                }
                if !store.projects.isEmpty { Divider() }
                Button("Add Folder…") { app.addProjectFromPanel() }
            } label: {
                toolLabel(store.currentProject?.title ?? "Add project")
            }
            .modifier(QuietMenu())

            Menu {
                ForEach(store.providers.filter(\.isReady)) { provider in
                    Section(provider.name) {
                        ForEach(provider.models) { model in
                            Button(model.name) {
                                store.spawnProviderID = provider.id
                                store.spawnModelID = model.id
                            }
                        }
                    }
                }
            } label: {
                toolLabel(store.spawnModel?.name ?? "No model")
            }
            .modifier(QuietMenu())

            Menu {
                ForEach(RuntimeMode.allCases) { mode in
                    Button(mode.label) { store.spawnMode = mode }
                }
            } label: {
                toolLabel(store.spawnMode.label)
            }
            .modifier(QuietMenu())
        }
    }

    private func modelName(_ agent: AgentModel) -> String {
        app.store.provider(agent.snapshot.providerID)?.models.first { $0.id == agent.snapshot.model }?.name
            ?? agent.snapshot.model
    }

    private func toolLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Theme.ui(12))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .opacity(0.7)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
}

/// Strips a menu down to its label.
private struct QuietMenu: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// An approval request: what the agent wants, and the keys that answer it.
struct ApprovalBar: View {
    let agent: AgentModel
    let request: PendingRequest
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(agent.name) wants to \(verb)")
                .font(Theme.ui(13, .medium))

            if let prompt = request.prompt {
                Text(LiveLine.shortCommand(prompt))
                    .font(Theme.mono(12))
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
            }

            HStack(spacing: 16) {
                Spacer(minLength: 0)
                quiet("Deny", key: app.isTyping ? "⌘⌫" : "N") { app.store.respond(.decline, to: agent.id) }
                quiet("Always allow", key: app.isTyping ? "⌘⇧↩" : "⇧Y") { app.store.respond(.acceptForSession, to: agent.id) }
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
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .glassPanel(cornerRadius: 20, frost: max(app.settings.data.chatFrost, 0.35))
    }

    private var verb: String {
        switch request.kind {
        case .command: "run a command"
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
                    .font(Theme.text(11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
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
                        .font(Theme.text(12.5))
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
