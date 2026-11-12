import AppKit
import OstraCore
import SwiftUI

/// The center of the HUD: the chat pane, any pending request, and the chat box.
///
/// The pieces share one glass container, so they blend where they meet and
/// the pane grows out of the chat box when it opens.
struct ChatDock: View {
    /// The dock's width. `AppModel.dockPlacement` decides it.
    var width: CGFloat

    @Environment(AppModel.self) private var app
    @State private var inputHeight: CGFloat = 92
    /// The request bar's height. It starts at a typical bar's height, so the
    /// first bar and the pane's room for it arrive together.
    @State private var requestHeight: CGFloat = 124
    /// The pane height on screen. It follows the height the pane wants on a
    /// spring of its own, so content that changes with it, such as another
    /// agent's conversation, still changes at once.
    @State private var shownPaneHeight: CGFloat = 0
    /// The agent the dock showed on its last pass.
    @State private var shownAgentID: AgentID?

    var body: some View {
        let agent = app.store.selectedAgent
        let pinned = app.store.pinnedAgent
        let showPane = app.chatOpen && agent != nil
        let hasRequest = agent?.snapshot.pendingRequest != nil
        let gap = Theme.dockGap
        // The pane gives up height when a request bar needs room, so the dock
        // never grows past the top of the window.
        let tallest = max(170, min(
            app.chatPaneHeight,
            app.dockMaxHeight - inputHeight - gap - (hasRequest ? requestHeight + gap : 0)
        ))
        // A short conversation gets a short pane; the pane grows with it.
        let paneHeight = min(tallest, max(wantedHeight(agent, tab: app.chatTab), wantedHeight(pinned, tab: .chat))).rounded()

        GlassEffectContainer(spacing: gap) {
            VStack(spacing: gap) {
                if showPane, let agent {
                    HStack(spacing: gap) {
                        ChatPane(agent: agent)
                        if let pinned {
                            ChatPane(agent: pinned, isPinned: true)
                                .transition(.slide(from: .trailing))
                        }
                    }
                    .frame(height: shownPaneHeight)
                    .transition(.rise)
                    .zIndex(1)
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
                    // The bar sits under the pane, so the pane uncovers it
                    // as it moves up to make room.
                    .transition(.opacity)
                    .zIndex(0)
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
        }
        .onDisappear { app.hudRegions.set("chat", nil) }
        // The dock hangs from the bottom of the window. The frame sits inside
        // the animations, so when the pane changes height, or a request bar
        // joins the dock, the top edge moves and the bottom edge stays where
        // it is: for a tab, an agent, or a new message alike.
        .frame(maxHeight: .infinity, alignment: .bottom)
        // A request that arrives while you watch slides in. Switching to an
        // agent that already has one shows it at once.
        .animation(shownAgentID == agent?.id ? Motion.resize : nil, value: agent?.snapshot.pendingRequest?.id)
        .onChange(of: paneHeight, initial: true) { old, new in
            // The height catches up in a transaction of its own, so only
            // the pane's frame animates, never the text that changed with it.
            if showPane, old != new, shownPaneHeight > 0 {
                Motion.perform(Motion.resize) { shownPaneHeight = new }
            } else {
                shownPaneHeight = new
            }
        }
        .onChange(of: app.store.selectedAgentID, initial: true) { _, id in
            shownAgentID = id
        }
        .onChange(of: tallest, initial: true) { _, limit in
            app.chatPaneLimit = limit
        }
    }

    /// The pane height an agent's current view asks for.
    private func wantedHeight(_ agent: AgentModel?, tab: ChatTab) -> CGFloat {
        guard let agent else { return 0 }
        // Activity and Diff are reference views, so they take the full height.
        guard tab == .chat else { return .infinity }
        let header = Theme.headerHeight + 1
        guard agent.conversation.isLoaded, let content = app.conversationHeights[agent.id] else {
            return header + 132
        }
        // An empty conversation keeps room for its note. Otherwise the pane
        // hugs the conversation exactly, so it never shows slack to anchor.
        return header + max(content, agent.conversation.items.isEmpty ? 112 : 64)
    }
}

/// The chat box.
///
/// It always has the same form: the text on top, and a footer with the
/// attach button, what the message goes to, and one button that sends, or
/// stops the agent while it runs. With no agent selected, the message starts
/// a new agent, and the footer chooses its project, model, and permissions.
struct PromptInput: View {
    @Environment(AppModel.self) private var app
    @State private var height: CGFloat = 18

    var body: some View {
        @Bindable var app = app
        let agent = app.store.selectedAgent
        let attachments = app.attachments
        let shape = RoundedRectangle(cornerRadius: Theme.inputRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                AttachmentTray(attachments: attachments)
                    .transition(AnyTransition(Materialize(scale: 0.96, anchor: .bottomLeading)))
            }

            ZStack(alignment: .topLeading) {
                if app.draft.isEmpty {
                    Text(app.isDropTargeted ? "Drop to attach" : placeholder(agent))
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
                    onPaste: { app.attachFromPasteboard() },
                    register: { app.focus.chatInput = $0 }
                )
                .frame(height: height)
            }

            HStack(spacing: 16) {
                attachButton
                tools(agent)
                Spacer(minLength: 8)
                submitButton(agent)
            }
            .frame(height: 28)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .glassPanel(cornerRadius: Theme.inputRadius, frost: app.settings.data.chatFrost * 0.85)
        .overlay {
            if app.isDropTargeted {
                shape.strokeBorder(Theme.accent, lineWidth: 2)
                    .transition(.opacity)
            }
        }
        .animation(Motion.hover, value: app.isDropTargeted)
        .contentShape(shape)
        .onTapGesture { app.focusInput() }
    }

    private func placeholder(_ agent: AgentModel?) -> String {
        if let agent {
            return agent.phase == .awaitingInput ? "Answer \(agent.name)" : "Message \(agent.name)"
        }
        if let project = app.store.currentProject { return "New agent in \(project.title)" }
        return "Add a project to start an agent"
    }

    private var attachButton: some View {
        Button {
            app.chooseAttachments()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 28, alignment: .leading)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.pressable)
        .help(app.help("Attach files or images", .attachFiles) + ". Paste works too.")
    }

    /// One button, two jobs: it stops a running agent while there's nothing
    /// to send, and sends otherwise.
    private func submitButton(_ agent: AgentModel?) -> some View {
        let canSend = app.canSend
        let stops = !canSend && agent?.phase.isActive == true
        return Button {
            if stops, let agent {
                app.store.interrupt(agent.id)
            } else {
                app.submitDraft()
            }
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.system(size: stops ? 9 : 12, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(stops ? .secondary : .tertiary))
                .frame(width: 28, height: 28)
                .background(Circle().fill(canSend ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(stops ? 0.09 : 0.06))))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!canSend && !stops)
        .animation(Motion.hover, value: canSend)
        .animation(Motion.hover, value: stops)
        .help(stops ? app.help("Stop \(agent?.name ?? "the agent")", .stop) : "Send (↩)")
    }

    /// What the message goes to. The three places stay put: project, model,
    /// permissions. A new agent chooses all three; a running one has its
    /// project and model settled.
    @ViewBuilder
    private func tools(_ agent: AgentModel?) -> some View {
        let store = app.store
        if let agent {
            fixedLabel(store.project(agent.projectID)?.title ?? "Project")
            fixedLabel(modelName(agent))
            Menu {
                ForEach(RuntimeMode.allCases) { mode in
                    Toggle(mode.label, isOn: Binding(
                        get: { agent.snapshot.runtimeMode == mode },
                        set: { if $0 { store.setRuntimeMode(mode, for: agent.id) } }
                    ))
                }
            } label: {
                menuLabel(agent.snapshot.runtimeMode.label)
            }
            .modifier(QuietMenu())
        } else {
            Menu {
                ForEach(store.projects) { project in
                    Toggle(project.title, isOn: Binding(
                        get: { store.currentProject?.id == project.id },
                        set: { if $0 { store.currentProjectID = project.id } }
                    ))
                }
                if !store.projects.isEmpty { Divider() }
                Button("Add Folder…") { app.addProjectFromPanel() }
            } label: {
                menuLabel(store.currentProject?.title ?? "Add project")
            }
            .modifier(QuietMenu())

            Menu {
                ForEach(store.providers.filter(\.isReady)) { provider in
                    Section(provider.name) {
                        ForEach(provider.models) { model in
                            Toggle(model.name, isOn: Binding(
                                get: { store.spawnProvider?.id == provider.id && store.spawnModel?.id == model.id },
                                set: {
                                    guard $0 else { return }
                                    store.spawnProviderID = provider.id
                                    store.spawnModelID = model.id
                                }
                            ))
                        }
                    }
                }
            } label: {
                menuLabel(store.spawnModel?.name ?? "No model")
            }
            .modifier(QuietMenu())

            Menu {
                ForEach(RuntimeMode.allCases) { mode in
                    Toggle(mode.label, isOn: Binding(
                        get: { store.spawnMode == mode },
                        set: { if $0 { store.spawnMode = mode } }
                    ))
                }
            } label: {
                menuLabel(store.spawnMode.label)
            }
            .modifier(QuietMenu())
        }
    }

    private func modelName(_ agent: AgentModel) -> String {
        app.store.provider(agent.snapshot.providerID)?.models.first { $0.id == agent.snapshot.model }?.name
            ?? agent.snapshot.model
    }

    /// A setting that can't change anymore.
    private func fixedLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.ui(12))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    /// A setting that opens a menu.
    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Theme.ui(12))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .opacity(0.7)
        }
        .foregroundStyle(.secondary)
        .frame(height: 28)
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
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
            }

            HStack(spacing: 16) {
                Spacer(minLength: 0)
                quiet("Deny", key: key(.deny)) { app.store.respond(.decline, to: agent.id) }
                quiet("Always allow", key: key(.approveAlways)) { app.store.respond(.acceptForSession, to: agent.id) }
                Button {
                    app.store.respond(.accept, to: agent.id)
                } label: {
                    HStack(spacing: 6) {
                        Text("Allow").font(Theme.ui(13, .medium))
                        if let allow = key(.approve) {
                            Text(allow).font(Theme.mono(11, .medium)).opacity(0.7)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(Theme.accent))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .glassPanel(cornerRadius: 20, frost: max(app.settings.data.chatFrost, 0.35))
    }

    /// The key that works right now: a single key, or a chord while typing.
    private func key(_ command: Command) -> String? {
        app.keymap.label(for: command, typing: app.isTyping)
    }

    private var verb: String {
        switch request.kind {
        case .command: "run a command"
        case .fileChange: "change files"
        case .fileRead: "read a file"
        case .permission, .other, .userInput: "continue"
        }
    }

    private func quiet(_ title: String, key: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(Theme.ui(13, .medium))
                if let key {
                    Text(key).font(Theme.mono(11, .medium)).foregroundStyle(.tertiary)
                }
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
                    .font(Theme.text(12))
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
                        .font(Theme.text(13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}
