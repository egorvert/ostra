import Foundation

/// One row of an agent's conversation: a message, a tool call, a request, or a marker.
public struct TimelineItem: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case pending
        case running
        case waiting
        case completed
        case failed
        case cancelled
    }

    public enum Content: Hashable, Sendable {
        case userMessage(text: String)
        case assistantMessage(text: String, streaming: Bool)
        case reasoning(text: String, streaming: Bool)
        case command(CommandCall)
        case fileChange([FileChange])
        case tool(ToolCall)
        case approval(ApprovalRecord)
        case question(QuestionRecord)
        case plan(text: String)
        case todos([TodoEntry])
        case checkpoint([FileStat])
        case subagent(SubagentRecord)
        case notice(text: String, level: NoticeLevel)
    }

    public var id: String
    /// Sort key. Items order by `ordinal`, then by `id`.
    public var ordinal: Int
    public var runID: String?
    public var status: Status
    public var startedAt: Date?
    public var completedAt: Date?
    public var content: Content

    public init(
        id: String,
        ordinal: Int,
        runID: String? = nil,
        status: Status = .completed,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        content: Content
    ) {
        self.id = id
        self.ordinal = ordinal
        self.runID = runID
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.content = content
    }
}

public struct CommandCall: Hashable, Sendable {
    public var command: String
    /// A short label the engine supplies for synthetic commands, such as "Workspace ready".
    public var title: String?
    public var output: String?
    public var exitCode: Int?

    public init(command: String, title: String? = nil, output: String? = nil, exitCode: Int? = nil) {
        self.command = command
        self.title = title
        self.output = output
        self.exitCode = exitCode
    }
}

public struct FileChange: Hashable, Sendable {
    public enum Operation: String, Hashable, Sendable {
        case add
        case update
        case delete
        case rename
        case other
    }

    public var path: String
    public var operation: Operation
    public var oldPath: String?

    public init(path: String, operation: Operation, oldPath: String? = nil) {
        self.path = path
        self.operation = operation
        self.oldPath = oldPath
    }
}

/// A tool call that isn't a shell command or a file edit, such as a web search or an MCP tool.
public struct ToolCall: Hashable, Sendable {
    public var name: String
    /// A one-line summary of the input.
    public var summary: String?
    public var output: String?

    public init(name: String, summary: String? = nil, output: String? = nil) {
        self.name = name
        self.summary = summary
        self.output = output
    }
}

/// An approval request as it appears in the conversation, pending or resolved.
public struct ApprovalRecord: Hashable, Sendable {
    public var requestID: RequestID
    public var kind: PendingRequest.Kind
    public var prompt: String?
    /// Nil while the request waits for the user.
    public var decision: ApprovalDecision?

    public init(
        requestID: RequestID,
        kind: PendingRequest.Kind,
        prompt: String? = nil,
        decision: ApprovalDecision? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.prompt = prompt
        self.decision = decision
    }
}

/// A question the agent asked, pending or answered.
public struct QuestionRecord: Hashable, Sendable {
    public var requestID: RequestID
    public var questions: [PendingRequest.Question]
    /// The answers by question ID, once the user responds.
    public var answers: [String: String]

    public init(
        requestID: RequestID,
        questions: [PendingRequest.Question],
        answers: [String: String] = [:]
    ) {
        self.requestID = requestID
        self.questions = questions
        self.answers = answers
    }
}

public struct TodoEntry: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case pending
        case inProgress
        case completed
    }

    public var text: String
    public var state: State

    public init(text: String, state: State) {
        self.text = text
        self.state = state
    }
}

/// Per-file line counts that a checkpoint recorded.
public struct FileStat: Hashable, Sendable {
    public var path: String
    public var additions: Int
    public var deletions: Int

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

public struct SubagentRecord: Hashable, Sendable {
    public var name: String
    public var prompt: String?
    public var result: String?

    public init(name: String, prompt: String? = nil, result: String? = nil) {
        self.name = name
        self.prompt = prompt
        self.result = result
    }
}

public enum NoticeLevel: String, Hashable, Sendable {
    case info
    case warning
    case error
}

/// Run-level numbers for a conversation.
public struct ConversationMeta: Hashable, Sendable {
    /// The share of the model's context window in use, from 0 to 1.
    public var contextUsage: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    /// The number of completed runs. The diff request needs it.
    public var completedRunCount: Int

    public init(
        contextUsage: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        completedRunCount: Int = 0
    ) {
        self.contextUsage = contextUsage
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.completedRunCount = completedRunCount
    }
}

/// An update to one agent's conversation.
public enum ConversationEvent: Sendable {
    /// Replaces the whole timeline. Sent first, and again after a reconnect.
    case reset(items: [TimelineItem], meta: ConversationMeta)
    /// Inserts the item, or replaces the item with the same ID.
    case upsert(TimelineItem)
    case remove(id: String)
    case meta(ConversationMeta)
}
