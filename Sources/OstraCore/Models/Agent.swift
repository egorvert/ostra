import Foundation

/// A directory that agents work in.
public struct Project: Identifiable, Hashable, Sendable {
    public var id: ProjectID
    public var title: String
    /// Absolute path of the workspace root.
    public var path: String

    public init(id: ProjectID, title: String, path: String) {
        self.id = id
        self.title = title
        self.path = path
    }
}

/// How much an agent can do without asking.
public enum RuntimeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto
    case fullAccess = "full-access"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .approvalRequired: "Ask for everything"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }
}

/// Whether the agent acts or only plans.
public enum InteractionMode: String, Codable, Sendable, CaseIterable {
    case normal = "default"
    case plan
}

/// The lifecycle state that the canvas shows for an agent.
public enum AgentPhase: String, Hashable, Sendable, CaseIterable {
    /// The agent exists and has no work in flight.
    case idle
    /// A run is queued, preparing its workspace, or starting its provider session.
    case starting
    /// The agent is working.
    case working
    /// The agent waits for the user to approve an action.
    case awaitingApproval
    /// The agent asked the user a question.
    case awaitingInput
    /// The latest run finished.
    case done
    /// The latest run failed.
    case failed
    /// The user stopped the latest run.
    case interrupted

    /// True while a run is in flight and the agent doesn't wait for the user.
    public var isRunning: Bool { self == .starting || self == .working }

    /// True when the agent can't continue until the user acts.
    public var isBlockedOnUser: Bool { self == .awaitingApproval || self == .awaitingInput }

    /// True while the engine holds a live run for the agent.
    public var isActive: Bool { isRunning || isBlockedOnUser }
}

/// A choice the user can make on an approval request.
public enum ApprovalDecision: String, Codable, Sendable, CaseIterable {
    case accept
    case acceptForSession
    case acceptAlways
    case decline
    case cancel
}

/// A request that an agent raised and that waits for the user.
public struct PendingRequest: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case command
        case fileChange
        case fileRead
        case permission
        case userInput
        case other
    }

    public struct Option: Hashable, Sendable {
        public var decision: ApprovalDecision
        public var label: String
        public init(decision: ApprovalDecision, label: String) {
            self.decision = decision
            self.label = label
        }
    }

    /// One question of a user-input request.
    public struct Question: Identifiable, Hashable, Sendable {
        public var id: String
        public var header: String?
        public var prompt: String
        public var choices: [Choice]
        public var allowsMultiple: Bool
        public var allowsFreeText: Bool

        public struct Choice: Hashable, Sendable {
            public var label: String
            public var detail: String?
            public init(label: String, detail: String? = nil) {
                self.label = label
                self.detail = detail
            }
        }

        public init(
            id: String,
            header: String? = nil,
            prompt: String,
            choices: [Choice] = [],
            allowsMultiple: Bool = false,
            allowsFreeText: Bool = true
        ) {
            self.id = id
            self.header = header
            self.prompt = prompt
            self.choices = choices
            self.allowsMultiple = allowsMultiple
            self.allowsFreeText = allowsFreeText
        }
    }

    public var id: RequestID
    public var kind: Kind
    /// What the agent wants to do, for example the shell command.
    public var prompt: String?
    /// The decisions the engine accepts. Empty means the default set.
    public var options: [Option]
    /// Filled for `.userInput` requests.
    public var questions: [Question]

    public init(
        id: RequestID,
        kind: Kind,
        prompt: String? = nil,
        options: [Option] = [],
        questions: [Question] = []
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.options = options
        self.questions = questions
    }
}

/// Line counts for a set of changes.
public struct ChangeStats: Hashable, Sendable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int = 0, additions: Int = 0, deletions: Int = 0) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    public var isEmpty: Bool { files == 0 && additions == 0 && deletions == 0 }
}

/// The engine's view of one agent. The engine sends a new snapshot whenever a field changes.
public struct AgentSnapshot: Identifiable, Hashable, Sendable {
    public var id: AgentID
    public var projectID: ProjectID
    /// The task title.
    public var title: String
    /// The provider instance, for example `codex` or `claudeAgent`.
    public var providerID: String
    public var model: String
    public var runtimeMode: RuntimeMode
    public var interactionMode: InteractionMode
    public var phase: AgentPhase
    /// The error text when `phase` is `.failed`.
    public var errorMessage: String?
    public var pendingRequest: PendingRequest?
    public var branch: String?
    /// The directory the agent works in: its worktree, or the project root.
    public var workingDirectory: String?
    /// The run to stop when the user interrupts the agent.
    public var activeRunID: String?
    /// The parent agent when this agent is a subagent.
    public var parentID: AgentID?
    public var createdAt: Date
    public var updatedAt: Date
    /// When the latest run finished.
    public var completedAt: Date?
    /// When the user last opened the agent.
    public var lastVisitedAt: Date?
    public var isArchived: Bool

    public init(
        id: AgentID,
        projectID: ProjectID,
        title: String,
        providerID: String,
        model: String,
        runtimeMode: RuntimeMode = .autoAcceptEdits,
        interactionMode: InteractionMode = .normal,
        phase: AgentPhase = .idle,
        errorMessage: String? = nil,
        pendingRequest: PendingRequest? = nil,
        branch: String? = nil,
        workingDirectory: String? = nil,
        activeRunID: String? = nil,
        parentID: AgentID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        completedAt: Date? = nil,
        lastVisitedAt: Date? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.providerID = providerID
        self.model = model
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
        self.phase = phase
        self.errorMessage = errorMessage
        self.pendingRequest = pendingRequest
        self.branch = branch
        self.workingDirectory = workingDirectory
        self.activeRunID = activeRunID
        self.parentID = parentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastVisitedAt = lastVisitedAt
        self.isArchived = isArchived
    }

    /// True when the latest run finished after the user last looked.
    public var hasUnseenResult: Bool {
        guard phase == .done || phase == .failed, let completedAt else { return false }
        guard let lastVisitedAt else { return true }
        return completedAt > lastVisitedAt
    }

    /// True when the agent wants the user: a request, a failure, or an unseen result.
    public var needsAttention: Bool {
        phase.isBlockedOnUser || hasUnseenResult
    }
}

/// A coding agent runtime that the engine can drive, such as Codex or Claude.
public struct ProviderInfo: Identifiable, Hashable, Sendable {
    public struct Model: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var isDefault: Bool
        public init(id: String, name: String, isDefault: Bool = false) {
            self.id = id
            self.name = name
            self.isDefault = isDefault
        }
    }

    /// The provider instance ID.
    public var id: String
    public var name: String
    /// True when the provider is installed, enabled, and signed in.
    public var isReady: Bool
    /// Why the provider isn't ready.
    public var statusMessage: String?
    public var models: [Model]
    /// The runtime modes the provider accepts. Empty means all of them.
    public var supportedRuntimeModes: [RuntimeMode]

    public init(
        id: String,
        name: String,
        isReady: Bool,
        statusMessage: String? = nil,
        models: [Model] = [],
        supportedRuntimeModes: [RuntimeMode] = []
    ) {
        self.id = id
        self.name = name
        self.isReady = isReady
        self.statusMessage = statusMessage
        self.models = models
        self.supportedRuntimeModes = supportedRuntimeModes
    }

    public var defaultModel: Model? { models.first(where: \.isDefault) ?? models.first }

    public func supports(_ mode: RuntimeMode) -> Bool {
        supportedRuntimeModes.isEmpty || supportedRuntimeModes.contains(mode)
    }
}
