import OstraCore
import SwiftUI

/// Everything an agent did, step by step, with its plan and its usage.
struct ActivityView: View {
    let agent: AgentModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let items = agent.conversation.items
        let todos = latestTodos(items)
        let sections = runs(items)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                UsageStrip(agent: agent)

                if let todos {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Plan")
                        TodoList(entries: todos)
                    }
                }

                if sections.isEmpty {
                    Text("No activity yet")
                        .font(Theme.text(12.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let prompt = section.prompt {
                            Text(prompt)
                                .font(Theme.text(12.5, .medium))
                                .lineLimit(2)
                                .foregroundStyle(.primary.opacity(0.85))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(section.steps) { item in
                                StepLine(item: item, startsExpanded: item.status == .running)
                            }
                        }
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }

    private struct RunSection: Identifiable {
        var id: String
        var prompt: String?
        var steps: [TimelineItem]
    }

    /// Splits the timeline at each user message, keeping only the steps.
    private func runs(_ items: [TimelineItem]) -> [RunSection] {
        var sections: [RunSection] = []
        var current = RunSection(id: "start", prompt: nil, steps: [])
        for item in items {
            switch item.content {
            case let .userMessage(text):
                if !current.steps.isEmpty || current.prompt != nil { sections.append(current) }
                current = RunSection(id: item.id, prompt: text, steps: [])
            case .reasoning, .command, .fileChange, .tool, .checkpoint, .subagent:
                current.steps.append(item)
            default:
                break
            }
        }
        if !current.steps.isEmpty || current.prompt != nil { sections.append(current) }
        return sections.filter { !$0.steps.isEmpty }
    }

    private func latestTodos(_ items: [TimelineItem]) -> [TodoEntry]? {
        for item in items.reversed() {
            if case let .todos(entries) = item.content, !entries.isEmpty { return entries }
        }
        return nil
    }
}

/// Context use, tokens, model, and permissions for one agent.
struct UsageStrip: View {
    let agent: AgentModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let meta = agent.conversation.meta
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                metric("Model", app.store.provider(agent.snapshot.providerID)?.models.first { $0.id == agent.snapshot.model }?.name ?? agent.snapshot.model)
                metric("Permissions", agent.snapshot.runtimeMode.label)
                if let input = meta.inputTokens {
                    metric("Tokens in", Self.compact(input))
                }
                if let output = meta.outputTokens {
                    metric("Tokens out", Self.compact(output))
                }
            }
            if let usage = meta.contextUsage {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Context")
                            .font(Theme.ui(10.5, .medium))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(Int((usage * 100).rounded()))%")
                            .font(Theme.mono(10.5, .medium))
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(usage > 0.85 ? Theme.red : (usage > 0.65 ? Theme.amber : Theme.accent))
                                .frame(width: max(4, geometry.size.width * usage))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.ui(10.5, .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.text(12.5, .medium))
                .lineLimit(1)
        }
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.ui(10, .semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// The changes an agent made, one collapsible section per file.
struct DiffView: View {
    let agent: AgentModel
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var collapsed: Set<String> = []

    var body: some View {
        let state = app.diffs[agent.id] ?? AppModel.DiffState()

        VStack(spacing: 0) {
            header(state)
            Hairline()
            if state.files.isEmpty {
                placeholder(state)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                        ForEach(state.files) { file in
                            fileSection(file)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .task(id: agent.id) {
            if app.diffs[agent.id]?.loadedAt == nil { app.loadDiff(for: agent.id) }
        }
        .onChange(of: agent.changes) { _, _ in
            // A new checkpoint means the diff moved.
            app.loadDiff(for: agent.id)
        }
    }

    private func header(_ state: AppModel.DiffState) -> some View {
        let stats = UnifiedDiff.stats(state.files)
        return HStack(spacing: 8) {
            Text("\(stats.files) file\(stats.files == 1 ? "" : "s") changed")
                .font(Theme.text(12, .medium))
                .foregroundStyle(.secondary)
            Text("+\(stats.additions)").foregroundStyle(Theme.addition(scheme))
            Text("−\(stats.deletions)").foregroundStyle(Theme.deletion(scheme))
            Spacer()
            if state.isLoading {
                ProgressView().controlSize(.mini)
            }
            Button {
                app.loadDiff(for: agent.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("Reload the diff")
        }
        .font(Theme.mono(11.5, .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func placeholder(_ state: AppModel.DiffState) -> some View {
        VStack(spacing: 6) {
            if let error = state.error {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.amber)
                Text(error)
                    .font(Theme.text(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if state.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("No changes yet")
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(.secondary)
                Text("Files \(agent.name) edits show up here after each run.")
                    .font(Theme.text(12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileSection(_ file: FileDiff) -> some View {
        let isCollapsed = collapsed.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.snappy) {
                    if isCollapsed { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(kindLabel(file.kind))
                        .font(Theme.mono(9.5, .bold))
                        .foregroundStyle(kindColor(file.kind))
                        .frame(width: 13)
                    Text(file.path)
                        .font(Theme.mono(11.5, .medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    Text("+\(file.additions)").foregroundStyle(Theme.addition(scheme))
                    Text("−\(file.deletions)").foregroundStyle(Theme.deletion(scheme))
                }
                .font(Theme.mono(11, .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                Hairline()
                if file.isBinary {
                    Text("Binary file")
                        .font(Theme.text(12))
                        .foregroundStyle(.tertiary)
                        .padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { hunk in
                            Text(hunk.header)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.03))
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineView(line: line)
                            }
                        }
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        }
    }

    private func kindLabel(_ kind: FileDiff.Kind) -> String {
        switch kind {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    private func kindColor(_ kind: FileDiff.Kind) -> Color {
        switch kind {
        case .added: Theme.addition(scheme)
        case .modified: Theme.amber
        case .deleted: Theme.deletion(scheme)
        case .renamed: Theme.accent
        }
    }
}

private struct DiffLineView: View {
    let line: FileDiff.Line
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(marker)
                .frame(width: 18)
                .foregroundStyle(tint ?? Color.secondary.opacity(0.5))
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.mono(11))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 1.5)
        .padding(.trailing, 8)
        .background((tint ?? .clear).opacity(scheme == .dark ? 0.16 : 0.10))
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: ""
        }
    }

    private var tint: Color? {
        switch line.kind {
        case .addition: Theme.addition(scheme)
        case .deletion: Theme.deletion(scheme)
        case .context: nil
        }
    }
}
