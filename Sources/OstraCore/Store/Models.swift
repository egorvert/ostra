import CoreGraphics
import Foundation
import Observation

/// One agent's conversation, kept in timeline order.
@MainActor @Observable
public final class ConversationModel {
    public private(set) var items: [TimelineItem] = []
    public private(set) var meta = ConversationMeta()
    /// True once the engine delivered the first full timeline.
    public private(set) var isLoaded = false
    /// Bumps on every change, so views can follow the tail without diffing items.
    public private(set) var revision = 0

    public init() {}

    public func apply(_ event: ConversationEvent) {
        switch event {
        case let .reset(newItems, newMeta):
            items = newItems.sorted(by: Self.inOrder)
            meta = newMeta
            isLoaded = true
        case let .upsert(item):
            upsert(item)
        case let .remove(id):
            items.removeAll { $0.id == id }
        case let .meta(newMeta):
            meta = newMeta
        }
        revision &+= 1
    }

    private func upsert(_ item: TimelineItem) {
        // Streaming updates target the newest items, so search from the end.
        if let index = items.lastIndex(where: { $0.id == item.id }) {
            if items[index].ordinal == item.ordinal {
                if items[index] != item { items[index] = item }
                return
            }
            items.remove(at: index)
        }
        let insertion = items.lastIndex(where: { Self.inOrder($0, item) }).map { $0 + 1 } ?? 0
        items.insert(item, at: insertion)
    }

    private static func inOrder(_ a: TimelineItem, _ b: TimelineItem) -> Bool {
        a.ordinal != b.ordinal ? a.ordinal < b.ordinal : a.id < b.id
    }
}

/// An agent on the canvas: the engine's snapshot plus what Ostra adds to it.
@MainActor @Observable
public final class AgentModel: Identifiable {
    public nonisolated let id: AgentID
    public internal(set) var snapshot: AgentSnapshot
    /// The friendly name on the card. Ostra assigns it; the engine doesn't know it.
    public var name: String
    /// The card's center, in world points.
    public var position: CGPoint
    /// One line that says what the agent does right now.
    public internal(set) var liveLine: String
    /// Line counts across everything the agent changed.
    public internal(set) var changes = ChangeStats()
    public let conversation = ConversationModel()

    init(snapshot: AgentSnapshot, name: String, position: CGPoint) {
        id = snapshot.id
        self.snapshot = snapshot
        self.name = name
        self.position = position
        liveLine = LiveLine.fallback(for: snapshot)
    }

    public var phase: AgentPhase { snapshot.phase }
    public var title: String { snapshot.title }
    public var projectID: ProjectID { snapshot.projectID }
    public var needsAttention: Bool { snapshot.needsAttention }
}

/// Derives the one-line summary of what an agent is doing.
public enum LiveLine {
    public static func fallback(for snapshot: AgentSnapshot) -> String {
        switch snapshot.phase {
        case .idle: "Ready"
        case .starting: "Starting…"
        case .working: "Working…"
        case .awaitingApproval:
            snapshot.pendingRequest?.prompt.map { "Wants to run \(oneLine($0))" } ?? "Waiting for approval"
        case .awaitingInput:
            snapshot.pendingRequest?.questions.first.map { oneLine($0.prompt) } ?? "Has a question"
        case .done: "Done"
        case .failed: snapshot.errorMessage.map(oneLine) ?? "Failed"
        case .interrupted: "Stopped"
        }
    }

    public static func derive(snapshot: AgentSnapshot, items: [TimelineItem]) -> String {
        if snapshot.phase.isBlockedOnUser || snapshot.phase == .failed {
            return fallback(for: snapshot)
        }
        // Walk back to the newest item that says something.
        for item in items.reversed().prefix(12) {
            switch item.content {
            case let .assistantMessage(text, _):
                let line = lastLine(text)
                if !line.isEmpty { return line }
            case .reasoning:
                if snapshot.phase.isRunning { return "Thinking…" }
            case let .command(call):
                if let title = call.title, !title.isEmpty { continue }
                let verb = item.status == .running ? "Running" : "Ran"
                return "\(verb) \(oneLine(shortCommand(call.command)))"
            case let .fileChange(changes):
                guard let first = changes.first else { continue }
                let name = (first.path as NSString).lastPathComponent
                let more = changes.count > 1 ? " +\(changes.count - 1)" : ""
                return "\(item.status == .running ? "Editing" : "Edited") \(name)\(more)"
            case let .tool(call):
                return oneLine(call.summary.map { "\(call.name): \($0)" } ?? call.name)
            case let .subagent(record):
                return "Delegated to \(record.name)"
            case let .todos(entries):
                if let active = entries.first(where: { $0.state == .inProgress }) { return oneLine(active.text) }
            case .userMessage:
                if snapshot.phase.isRunning { return "Working…" }
                return fallback(for: snapshot)
            case .approval, .question, .plan, .checkpoint, .notice:
                continue
            }
        }
        return fallback(for: snapshot)
    }

    static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    static func lastLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""
        return stripInlineMarkdown(line.trimmingCharacters(in: .whitespaces))
    }

    /// Unwraps `zsh -lc '…'`, which is how providers report shell commands.
    public static func shortCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc ", "/bin/sh -c ", "sh -c "] {
            guard trimmed.hasPrefix(shell) else { continue }
            var inner = String(trimmed.dropFirst(shell.count))
            if inner.count >= 2, let first = inner.first, first == "'" || first == "\"", inner.last == first {
                inner = String(inner.dropFirst().dropLast())
            }
            return inner
        }
        return trimmed
    }

    static func stripInlineMarkdown(_ text: String) -> String {
        var result = text
        for token in ["**", "__", "`"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        for prefix in ["- ", "* ", "> ", "# ", "## ", "### "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        return result
    }
}

/// Which agents the cycle keys visit.
public enum CycleFilter: String, Codable, CaseIterable, Sendable {
    case all
    case attention
    case running

    public var label: String {
        switch self {
        case .all: "All"
        case .attention: "Needs you"
        case .running: "Running"
        }
    }

    public var next: CycleFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// A short message that floats over the canvas.
public struct Toast: Identifiable, Sendable {
    public enum Kind: Sendable {
        case info
        case success
        case error
    }

    public var id = UUID()
    public var kind: Kind
    public var text: String
    /// The label for the toast's button, such as "Undo".
    public var actionLabel: String?

    public init(kind: Kind = .info, text: String, actionLabel: String? = nil) {
        self.kind = kind
        self.text = text
        self.actionLabel = actionLabel
    }
}

/// What Ostra remembers between launches that the engine doesn't hold.
public struct PersistedState: Codable, Sendable {
    public var names: [String: String] = [:]
    public var positions: [String: CGPoint] = [:]
    public var projectAnchors: [String: CGPoint] = [:]
    public var camera = CameraState()
    public var currentProjectID: String?
    public var cycleFilter: CycleFilter = .all
    public var spawnProviderID: String?
    public var spawnModelID: String?
    public var spawnMode: RuntimeMode = .autoAcceptEdits

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        names = try container.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        positions = try container.decodeIfPresent([String: CGPoint].self, forKey: .positions) ?? [:]
        projectAnchors = try container.decodeIfPresent([String: CGPoint].self, forKey: .projectAnchors) ?? [:]
        camera = try container.decodeIfPresent(CameraState.self, forKey: .camera) ?? CameraState()
        currentProjectID = try container.decodeIfPresent(String.self, forKey: .currentProjectID)
        cycleFilter = try container.decodeIfPresent(CycleFilter.self, forKey: .cycleFilter) ?? .all
        spawnProviderID = try container.decodeIfPresent(String.self, forKey: .spawnProviderID)
        spawnModelID = try container.decodeIfPresent(String.self, forKey: .spawnModelID)
        spawnMode = try container.decodeIfPresent(RuntimeMode.self, forKey: .spawnMode) ?? .autoAcceptEdits
    }
}
