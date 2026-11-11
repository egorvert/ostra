import AppKit
import OstraCore
import SwiftUI

/// A row of the conversation.
///
/// The structure follows the common chat pattern: your messages sit in a
/// quiet bubble on the right, the agent's replies are plain text on the left,
/// and the work between them (thinking, commands, edits) folds into one line
/// that opens on demand.
enum ChatRow: Identifiable {
    case user(id: String, text: String, attachments: [Attachment])
    case assistant(id: String, text: String, streaming: Bool)
    case work(id: String, items: [TimelineItem])
    case changes(id: String, files: [FileStat])
    case approval(id: String, record: ApprovalRecord)
    case question(id: String, record: QuestionRecord)
    case plan(id: String, text: String)
    case todos(id: String, entries: [TodoEntry])
    case notice(id: String, text: String, level: NoticeLevel)

    var id: String {
        switch self {
        case let .user(id, _, _), let .assistant(id, _, _), let .work(id, _), let .changes(id, _),
             let .approval(id, _), let .question(id, _), let .plan(id, _), let .todos(id, _),
             let .notice(id, _, _):
            id
        }
    }

    /// The space above the row. A new turn gets more air than a step within one.
    var topSpacing: CGFloat {
        switch self {
        case .user: 30
        case .assistant: 16
        case .work, .plan, .todos: 16
        case .changes, .approval, .question, .notice: 12
        }
    }

    static func rows(from items: [TimelineItem]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var work: [TimelineItem] = []

        func flush() {
            guard let first = work.first else { return }
            rows.append(.work(id: "work-\(first.id)", items: work))
            work.removeAll()
        }

        for item in items {
            switch item.content {
            case let .userMessage(text, attachments):
                flush()
                rows.append(.user(id: item.id, text: text, attachments: attachments))
            case let .assistantMessage(text, streaming):
                if text.isEmpty { continue }
                flush()
                rows.append(.assistant(id: item.id, text: text, streaming: streaming))
            case let .command(call):
                // Steps the engine adds itself, such as "Workspace ready",
                // show in Activity only.
                if call.title == nil { work.append(item) }
            case .reasoning, .fileChange, .tool, .subagent:
                work.append(item)
            case let .checkpoint(files):
                flush()
                if !files.isEmpty { rows.append(.changes(id: item.id, files: files)) }
            case let .approval(record):
                // A pending request shows in the bar above the chat box.
                if record.decision == nil, item.status != .completed { continue }
                flush()
                rows.append(.approval(id: item.id, record: record))
            case let .question(record):
                if record.answers.isEmpty, item.status != .completed { continue }
                flush()
                rows.append(.question(id: item.id, record: record))
            case let .plan(text):
                flush()
                rows.append(.plan(id: item.id, text: text))
            case let .todos(entries):
                flush()
                rows.append(.todos(id: item.id, entries: entries))
            case let .notice(text, level):
                flush()
                rows.append(.notice(id: item.id, text: text, level: level))
            }
        }
        flush()
        return rows
    }
}

/// The conversation with one agent.
struct ChatTimeline: View {
    let agent: AgentModel
    @Environment(AppModel.self) private var app
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    /// The row search jumped to, while its highlight shows.
    @State private var flashed: String?

    var body: some View {
        let conversation = agent.conversation
        let rows = ChatRow.rows(from: conversation.items)
        let lastAssistant = rows.last { if case .assistant = $0 { true } else { false } }?.id

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ChatRowView(row: row, agent: agent, isLatestReply: row.id == lastAssistant)
                        .background {
                            // A row that search jumped to glows for a moment.
                            if flashed == row.id {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.accent.opacity(0.10))
                                    .padding(-8)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.top, index == 0 ? 0 : row.topSpacing)
                        .id(row.id)
                }
                if agent.phase.isRunning, !endsWithLiveOutput(rows) {
                    Shimmer(text: agent.phase == .starting ? "Starting" : "Thinking")
                        .font(Theme.text(13))
                        .padding(.top, rows.isEmpty ? 0 : 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollTargetLayout()
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { height in
                app.conversationHeights[agent.id] = height
            }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 28
        } action: { _, value in
            atBottom = value
        }
        .onChange(of: conversation.revision) { _, _ in
            // Follow new output only while the reader is at the end.
            if atBottom { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: app.scrollTargets[agent.id], initial: true) { _, target in
            guard let target else { return }
            app.scrollTargets[agent.id] = nil
            jump(to: target)
        }
        .overlay {
            if rows.isEmpty, !agent.phase.isRunning {
                emptyState(loaded: conversation.isLoaded)
            }
        }
        .overlay(alignment: .bottom) {
            if !atBottom {
                Button {
                    withAnimation(Motion.snappy) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .glassEffect(.regular.interactive(), in: Circle())
                .padding(.bottom, 12)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .help("Jump to the latest message")
            }
        }
        .animation(Motion.easeOut(0.16), value: atBottom)
    }

    /// Brings a row to the middle of the pane and marks it for a moment.
    private func jump(to row: String) {
        Task {
            // Give a pane that just opened one pass to lay out its rows.
            try? await Task.sleep(for: .milliseconds(60))
            position.scrollTo(id: row, anchor: .center)
            withAnimation(Motion.hover) { flashed = row }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.easeOut(0.5)) { flashed = nil }
        }
    }

    private func endsWithLiveOutput(_ rows: [ChatRow]) -> Bool {
        switch rows.last {
        case let .assistant(_, _, streaming): streaming
        case let .work(_, items): items.last?.status == .running
        default: false
        }
    }

    private func emptyState(loaded: Bool) -> some View {
        VStack(spacing: 5) {
            if loaded {
                Text("No messages yet")
                    .font(Theme.ui(13, .medium))
                Text("Tell \(agent.name) what to do.")
                    .font(Theme.text(13))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct ChatRowView: View {
    let row: ChatRow
    let agent: AgentModel
    var isLatestReply = false

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        switch row {
        case let .user(_, text, attachments):
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    MessageAttachments(attachments: attachments)
                }
                if !text.isEmpty {
                    HStack(alignment: .bottom, spacing: 6) {
                        Spacer(minLength: 48)
                        CopyButton(text: text)
                            .opacity(hovering ? 1 : 0)
                        Text(text)
                            .font(Theme.text(14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.primary.opacity(scheme == .dark ? 0.11 : 0.055))
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)

        case let .assistant(_, text, streaming):
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: text, size: 14)
                // Only the latest reply keeps room for its actions. Earlier
                // ones show them on hover, in the gap below.
                if !streaming, isLatestReply {
                    CopyButton(text: text)
                        .opacity(hovering ? 1 : 0.55)
                        .padding(.leading, -5)
                }
            }
            .padding(.trailing, 20)
            .overlay(alignment: .bottomLeading) {
                if !streaming, !isLatestReply {
                    CopyButton(text: text)
                        .opacity(hovering ? 1 : 0)
                        .offset(x: -5, y: 21)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)

        case let .work(_, items):
            WorkRow(items: items, agentID: agent.id)

        case let .changes(_, files):
            ChangesRow(files: files)

        case let .approval(_, record):
            ApprovalLine(record: record)

        case let .question(_, record):
            QuestionLine(record: record)

        case let .plan(_, text):
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan")
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(.secondary)
                MarkdownView(text: text, size: 14)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }

        case let .todos(_, entries):
            TodoList(entries: entries)

        case let .notice(_, text, level):
            HStack(spacing: 7) {
                if level != .info {
                    Circle()
                        .fill(level == .error ? Theme.red : Theme.amber)
                        .frame(width: 6, height: 6)
                }
                Text(text)
                    .font(Theme.text(13))
                    .foregroundStyle(level == .error ? AnyShapeStyle(Theme.red) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
            }
        }
    }
}

/// A small button that copies text and confirms with a check.
struct CopyButton: View {
    var text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "square.on.square")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(copied ? AnyShapeStyle(Theme.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help("Copy")
    }
}

/// Text with a soft light that sweeps across it, for work in progress.
struct Shimmer: View {
    var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        Text(text)
                            .foregroundStyle(.primary.opacity(0.85))
                            .fixedSize()
                            .mask(alignment: .leading) {
                                LinearGradient(
                                    colors: [.clear, .black, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 64)
                                .offset(x: sweeping ? geometry.size.width : -64)
                            }
                    }
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    sweeping = true
                }
            }
            .accessibilityLabel(text)
    }
}

/// The work between two messages, folded into one line until the reader opens it.
struct WorkRow: View {
    let items: [TimelineItem]
    var agentID: AgentID?
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if let running = items.last(where: { $0.status == .running }) {
                        Shimmer(text: StepText.progress(running))
                            .lineLimit(1)
                    } else {
                        Text(summary)
                            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(Theme.text(13))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(items) { item in
                        StepLine(item: item, agentID: agentID)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1)
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    private var summary: String {
        var commands = 0
        var files = Set<String>()
        var tools = 0
        var thought = false
        for item in items {
            switch item.content {
            case let .command(call): if call.title == nil { commands += 1 }
            case let .fileChange(changes): files.formUnion(changes.map(\.path))
            case .tool, .subagent: tools += 1
            case .reasoning: thought = true
            default: break
            }
        }
        var parts: [String] = []
        if commands > 0 { parts.append("ran \(commands) command\(commands == 1 ? "" : "s")") }
        if !files.isEmpty { parts.append("edited \(files.count) file\(files.count == 1 ? "" : "s")") }
        if tools > 0 { parts.append("used \(tools) tool\(tools == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append(thought ? "thought" : "worked") }
        let sentence = parts.joined(separator: ", ")
        let text = sentence.prefix(1).uppercased() + sentence.dropFirst()
        guard let duration else { return text }
        return "\(text) for \(duration)"
    }

    /// How long the work took, when the engine recorded both ends.
    private var duration: String? {
        guard let start = items.compactMap(\.startedAt).min(),
              let end = items.compactMap(\.completedAt).max() else { return nil }
        let seconds = Int(end.timeIntervalSince(start).rounded())
        guard seconds >= 1 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// Wording for a step of work.
enum StepText {
    static func title(_ item: TimelineItem) -> String {
        switch item.content {
        case let .command(call):
            call.title ?? LiveLine.shortCommand(call.command)
        case let .fileChange(changes):
            changes.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
        case let .tool(call):
            call.summary.map { "\(call.name) · \($0)" } ?? call.name
        case let .reasoning(text, _):
            text.isEmpty ? "Thinking" : text
        case let .checkpoint(files):
            "Checkpoint · \(files.count) file\(files.count == 1 ? "" : "s")"
        case let .subagent(record):
            "Subagent · \(record.name)"
        default:
            ""
        }
    }

    /// The line to show while the step runs.
    static func progress(_ item: TimelineItem) -> String {
        switch item.content {
        case let .command(call): "Running \(call.title ?? LiveLine.shortCommand(call.command))"
        case .fileChange: "Editing \(title(item))"
        case .reasoning: "Thinking"
        case let .tool(call): "Using \(call.name)"
        case let .subagent(record): "Waiting on \(record.name)"
        default: "Working"
        }
    }

    static func symbol(_ item: TimelineItem) -> String {
        switch item.content {
        case .command: "terminal"
        case .fileChange: "pencil"
        case .tool: "wrench.and.screwdriver"
        case .reasoning: "sparkle"
        case .checkpoint: "flag"
        case .subagent: "person.2"
        default: "circle"
        }
    }
}

/// One step of work: an icon, a title, and output that opens on demand.
struct StepLine: View {
    let item: TimelineItem
    /// The agent that ran the step, so the row can fetch command output on demand.
    var agentID: AgentID?
    var startsExpanded = false
    @State private var expanded: Bool?
    @State private var fetchedOutput: String?
    @State private var fetchFailed = false
    @State private var hovering = false
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    private var isExpanded: Bool { expanded ?? startsExpanded }
    private var isOpenable: Bool { detail != nil || canFetchOutput }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: StepText.symbol(item))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                titleText
                    .lineLimit(isExpanded ? 8 : 1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                trailing
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                guard isOpenable else { return }
                withAnimation(Motion.snappy) { expanded = !isExpanded }
                if isExpanded { fetchOutputIfNeeded() }
            }

            if isExpanded, detail == nil, canFetchOutput {
                Text("Loading output")
                    .font(Theme.text(12))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }

            if isExpanded, let detail {
                CodeBlock(language: nil, text: detail, size: 12)
                    .padding(.leading, 22)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var titleText: some View {
        switch item.content {
        case .command:
            Text(StepText.title(item))
                .font(Theme.mono(12))
                .foregroundStyle(.primary.opacity(0.82))
        case .reasoning:
            Text(StepText.title(item))
                .font(Theme.text(13))
                .foregroundStyle(.secondary)
        default:
            Text(StepText.title(item))
                .font(Theme.text(13))
                .foregroundStyle(.primary.opacity(0.82))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .running, .pending:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .failed:
            Text("Failed").font(Theme.text(12)).foregroundStyle(Theme.red)
        case .cancelled:
            Text("Stopped").font(Theme.text(12)).foregroundStyle(.tertiary)
        case .waiting, .completed:
            if case let .command(call) = item.content, let code = call.exitCode, code != 0 {
                Text("exit \(code)").font(Theme.mono(11)).foregroundStyle(Theme.red)
            } else if isOpenable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .opacity(hovering || isExpanded ? 1 : 0)
            }
        }
    }

    /// The text that shows when the step opens.
    private var detail: String? {
        switch item.content {
        case let .command(call):
            guard let output = call.output ?? fetchedOutput, !output.isEmpty else { return nil }
            return output
        case let .tool(call):
            return call.output?.isEmpty == false ? call.output : nil
        case let .fileChange(changes):
            guard changes.count > 1 || changes.first?.oldPath != nil else { return nil }
            return changes.map { "\($0.operation.rawValue)  \($0.path)" }.joined(separator: "\n")
        case let .checkpoint(files):
            guard !files.isEmpty else { return nil }
            return files.map { "+\($0.additions) −\($0.deletions)  \($0.path)" }.joined(separator: "\n")
        case let .subagent(record):
            return [record.prompt, record.result].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
        case let .reasoning(text, _):
            return text.count > 90 ? text : nil
        default:
            return nil
        }
    }

    /// True for a finished command whose output the engine holds back until asked.
    private var canFetchOutput: Bool {
        guard agentID != nil, !fetchFailed, case let .command(call) = item.content else { return false }
        return call.output == nil && call.title == nil && fetchedOutput == nil && item.status != .running
    }

    private func fetchOutputIfNeeded() {
        guard canFetchOutput, let agentID else { return }
        let backend = app.store.backend
        let itemID = item.id
        Task {
            let output = try? await backend.commandOutput(for: agentID, itemID: itemID)
            if let output, !output.isEmpty {
                fetchedOutput = output
            } else {
                fetchFailed = true
            }
        }
    }
}

/// What a run changed, with a way into the diff.
private struct ChangesRow: View {
    let files: [FileStat]
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button {
            app.setChatTab(.diff)
        } label: {
            HStack(spacing: 8) {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                    .foregroundStyle(.secondary)
                Text("+\(files.reduce(0) { $0 + $1.additions })")
                    .foregroundStyle(Theme.addition(scheme))
                Text("−\(files.reduce(0) { $0 + $1.deletions })")
                    .foregroundStyle(Theme.deletion(scheme))
                Spacer(minLength: 8)
                Text("View diff")
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .font(Theme.text(13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}

private struct ApprovalLine: View {
    let record: ApprovalRecord

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(Theme.text(13))
                .foregroundStyle(.tertiary)
            if let prompt = record.prompt {
                Text(LiveLine.shortCommand(prompt))
                    .font(Theme.mono(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var label: String {
        switch record.decision {
        case nil: "Waiting for approval"
        case .accept: "You allowed"
        case .acceptForSession, .acceptAlways: "You always allow"
        case .decline: "You denied"
        case .cancel: "Cancelled"
        }
    }
}

private struct QuestionLine: View {
    let record: QuestionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(record.questions) { question in
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.prompt)
                        .font(Theme.text(13))
                        .foregroundStyle(.secondary)
                    if let answer = record.answers[question.id] {
                        Text(answer)
                            .font(Theme.text(14, .medium))
                    }
                }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 2)
        }
    }
}

struct TodoList: View {
    let entries: [TodoEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(entry.state))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.state == .pending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    Text(entry.text)
                        .font(Theme.text(13, entry.state == .inProgress ? .medium : .regular))
                        .foregroundStyle(entry.state == .completed ? .secondary : .primary)
                        .strikethrough(entry.state == .completed, color: .secondary.opacity(0.5))
                }
            }
        }
    }

    private func symbol(_ state: TodoEntry.State) -> String {
        switch state {
        case .pending: "circle"
        case .inProgress: "circle.dotted.circle"
        case .completed: "checkmark.circle.fill"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
