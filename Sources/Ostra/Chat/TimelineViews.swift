import OstraCore
import SwiftUI

/// A row of the chat view. Consecutive tool steps collapse into one row, so
/// the chat reads as a conversation and the Activity view holds the detail.
enum ChatRow: Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, text: String, streaming: Bool)
    case steps(id: String, items: [TimelineItem])
    case approval(id: String, record: ApprovalRecord)
    case question(id: String, record: QuestionRecord)
    case plan(id: String, text: String)
    case todos(id: String, entries: [TodoEntry])
    case notice(id: String, text: String, level: NoticeLevel)

    var id: String {
        switch self {
        case let .user(id, _), let .assistant(id, _, _), let .steps(id, _), let .approval(id, _),
             let .question(id, _), let .plan(id, _), let .todos(id, _), let .notice(id, _, _):
            id
        }
    }

    static func rows(from items: [TimelineItem]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var steps: [TimelineItem] = []

        func flush() {
            guard let first = steps.first else { return }
            rows.append(.steps(id: "steps-\(first.id)", items: steps))
            steps.removeAll()
        }

        for item in items {
            switch item.content {
            case let .userMessage(text):
                flush()
                rows.append(.user(id: item.id, text: text))
            case let .assistantMessage(text, streaming):
                if text.isEmpty { continue }
                flush()
                rows.append(.assistant(id: item.id, text: text, streaming: streaming))
            case .reasoning, .command, .fileChange, .tool, .checkpoint, .subagent:
                steps.append(item)
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

    var body: some View {
        let conversation = agent.conversation
        let rows = ChatRow.rows(from: conversation.items)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if rows.isEmpty {
                    emptyState(loaded: conversation.isLoaded)
                }
                ForEach(rows) { row in
                    ChatRowView(row: row, agent: agent)
                }
                if agent.phase.isRunning, !endsWithLiveOutput(rows) {
                    HStack(spacing: 8) {
                        TypingDots(dot: 5)
                            .foregroundStyle(.secondary)
                        Text(agent.phase == .starting ? "Starting" : "Working")
                            .font(Theme.text(12))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.automatic)
    }

    private func endsWithLiveOutput(_ rows: [ChatRow]) -> Bool {
        switch rows.last {
        case let .assistant(_, _, streaming): streaming
        case let .steps(_, items): items.last?.status == .running
        default: false
        }
    }

    private func emptyState(loaded: Bool) -> some View {
        VStack(spacing: 6) {
            if loaded {
                Text("No messages yet")
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(.secondary)
                Text("Say what \(agent.name) should do.")
                    .font(Theme.text(12))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

struct ChatRowView: View {
    let row: ChatRow
    let agent: AgentModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch row {
        case let .user(_, text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .font(Theme.text(13.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.06))
                    }
            }

        case let .assistant(_, text, _):
            MarkdownView(text: text)

        case let .steps(_, items):
            StepsRow(items: items)

        case let .approval(_, record):
            ApprovalLine(record: record)

        case let .question(_, record):
            QuestionLine(record: record)

        case let .plan(_, text):
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan")
                    .font(Theme.ui(11.5, .medium))
                    .foregroundStyle(.tertiary)
                MarkdownView(text: text, size: 13)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04))
            }

        case let .todos(_, entries):
            TodoList(entries: entries)

        case let .notice(_, text, level):
            HStack(spacing: 6) {
                Image(systemName: level == .error ? "exclamationmark.triangle.fill" : (level == .warning ? "exclamationmark.circle" : "info.circle"))
                    .font(.system(size: 10.5))
                Text(text)
                    .font(Theme.text(11.5))
                    .textSelection(.enabled)
            }
            .foregroundStyle(level == .error ? Theme.red : (level == .warning ? Theme.amber : Color.secondary))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// A run of tool steps, collapsed to one line until the user opens it.
struct StepsRow: View {
    let items: [TimelineItem]
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if let running = items.last(where: { $0.status == .running }) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                        Text(StepText.title(running))
                            .lineLimit(1)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text(summary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 0.9 : 0.4)
                }
                .font(Theme.text(12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items) { item in
                        StepLine(item: item)
                    }
                }
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1.5)
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
        if thought { parts.append("thought") }
        if commands > 0 { parts.append("ran \(commands) command\(commands == 1 ? "" : "s")") }
        if !files.isEmpty { parts.append("edited \(files.count) file\(files.count == 1 ? "" : "s")") }
        if tools > 0 { parts.append("used \(tools) tool\(tools == 1 ? "" : "s")") }
        if parts.isEmpty { return "Saved a checkpoint" }
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}

/// Wording for a tool step.
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

    static func symbol(_ item: TimelineItem) -> String {
        switch item.content {
        case .command: "terminal"
        case .fileChange: "pencil.line"
        case .tool: "wrench.and.screwdriver"
        case .reasoning: "sparkle"
        case .checkpoint: "flag"
        case .subagent: "person.2"
        default: "circle"
        }
    }
}

/// One tool step: an icon, a title, and expandable output.
struct StepLine: View {
    let item: TimelineItem
    var startsExpanded = false
    @State private var expanded: Bool?
    @Environment(\.colorScheme) private var scheme

    private var isExpanded: Bool { expanded ?? startsExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: StepText.symbol(item))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                titleText
                    .lineLimit(isExpanded ? 6 : 1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                trailing
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard detail != nil else { return }
                withAnimation(Motion.snappy) { expanded = !isExpanded }
            }

            if isExpanded, let detail {
                CodeBlock(language: nil, text: detail, size: 11.5)
                    .padding(.leading, 21)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var titleText: some View {
        switch item.content {
        case .command:
            Text(StepText.title(item))
                .font(Theme.mono(11.5))
                .foregroundStyle(.primary.opacity(0.85))
        case .reasoning:
            Text(StepText.title(item))
                .font(Theme.text(12))
                .foregroundStyle(.secondary)
        case let .checkpoint(files):
            HStack(spacing: 5) {
                Text(StepText.title(item)).foregroundStyle(.secondary)
                Text("+\(files.reduce(0) { $0 + $1.additions })").foregroundStyle(Theme.addition(scheme))
                Text("−\(files.reduce(0) { $0 + $1.deletions })").foregroundStyle(Theme.deletion(scheme))
            }
            .font(Theme.text(12))
        default:
            Text(StepText.title(item))
                .font(Theme.text(12))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .running, .pending:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(Theme.red)
        case .cancelled:
            Image(systemName: "slash.circle").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        case .waiting, .completed:
            if case let .command(call) = item.content, let code = call.exitCode, code != 0 {
                Text("exit \(code)").font(Theme.mono(10)).foregroundStyle(Theme.red)
            } else if detail != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
    }

    /// The text that shows when the step opens.
    private var detail: String? {
        switch item.content {
        case let .command(call):
            guard let output = call.output, !output.isEmpty else { return nil }
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
}

private struct ApprovalLine: View {
    let record: ApprovalRecord

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(label)
                .font(Theme.text(12))
                .foregroundStyle(.secondary)
            if let prompt = record.prompt {
                Text(LiveLine.shortCommand(prompt))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var symbol: String {
        switch record.decision {
        case nil: "hand.raised.fill"
        case .accept, .acceptForSession, .acceptAlways: "checkmark.shield"
        case .decline, .cancel: "xmark.shield"
        }
    }

    private var tint: Color {
        switch record.decision {
        case nil: Theme.amber
        case .accept, .acceptForSession, .acceptAlways: Theme.green
        case .decline, .cancel: Theme.red
        }
    }

    private var label: String {
        switch record.decision {
        case nil: "Waiting for approval:"
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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(record.questions) { question in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.bubble")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(question.prompt)
                            .font(Theme.text(13, .medium))
                    }
                    if let answer = record.answers[question.id] {
                        Text(answer)
                            .font(Theme.text(12.5))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 19)
                    }
                }
            }
        }
    }
}

struct TodoList: View {
    let entries: [TodoEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: symbol(entry.state))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.state == .completed ? Theme.green : (entry.state == .inProgress ? Theme.accent : Color.secondary))
                    Text(entry.text)
                        .font(Theme.text(12.5, entry.state == .inProgress ? .medium : .regular))
                        .foregroundStyle(entry.state == .completed ? .secondary : .primary)
                        .strikethrough(entry.state == .completed, color: .secondary.opacity(0.6))
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
