import Foundation

/// Where the engine connection stands.
public enum ConnectionState: Hashable, Sendable {
    case idle
    /// The engine runtime downloads or unpacks. `progress` runs from 0 to 1 when known.
    case preparing(message: String, progress: Double?)
    case starting
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case failed(message: String)

    public var isReady: Bool { self == .ready }
}

/// A change to the engine-wide state: the connection, providers, projects, and agents.
public enum BackendEvent: Sendable {
    case connection(ConnectionState)
    case providers([ProviderInfo])
    /// Replaces every project and agent. Sent after each connect.
    case snapshot(projects: [Project], agents: [AgentSnapshot])
    case projectUpserted(Project)
    case projectRemoved(ProjectID)
    case agentUpserted(AgentSnapshot)
    case agentRemoved(AgentID)
}

/// Where a new agent works.
public enum WorkspaceStrategy: Hashable, Sendable {
    /// The project directory itself.
    case projectRoot
    /// A fresh git worktree cut from `baseRef`.
    case newWorktree(baseRef: String)
}

public struct LaunchRequest: Sendable {
    public var projectID: ProjectID
    /// The first message for the agent.
    public var prompt: String
    /// Files, images, and pasted text that go with the first message.
    public var attachments: [Attachment]
    /// The task title. When nil, the engine derives one from the prompt.
    public var title: String?
    public var providerID: String
    public var model: String
    public var runtimeMode: RuntimeMode
    public var interactionMode: InteractionMode
    public var workspace: WorkspaceStrategy

    public init(
        projectID: ProjectID,
        prompt: String,
        attachments: [Attachment] = [],
        title: String? = nil,
        providerID: String,
        model: String,
        runtimeMode: RuntimeMode = .autoAcceptEdits,
        interactionMode: InteractionMode = .normal,
        workspace: WorkspaceStrategy = .projectRoot
    ) {
        self.projectID = projectID
        self.prompt = prompt
        self.attachments = attachments
        self.title = title
        self.providerID = providerID
        self.model = model
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
        self.workspace = workspace
    }
}

/// How a message reaches an agent that's already working.
public enum MessageDelivery: Sendable {
    /// Steer the active run when one exists; otherwise start a run.
    case automatic
    /// Wait for the active run to finish, then start a run.
    case queue
}

public struct BackendError: Error, LocalizedError, Sendable, Hashable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The engine that runs agents.
///
/// The app talks to agents only through this protocol, so the engine can change
/// without touching the UI. `T3Backend` drives a local T3 Code server.
/// `MockBackend` simulates agents for previews, tests, and demo mode.
public protocol AgentBackend: AnyObject, Sendable {
    /// Engine-wide events. Each call returns an independent stream that starts
    /// with the current connection state, providers, and a snapshot.
    func events() -> AsyncStream<BackendEvent>

    /// Starts the engine and keeps the connection alive until `shutdown()`.
    func start() async

    /// Stops the engine and every process it owns.
    func shutdown() async

    func addProject(path: String, title: String?) async throws -> Project
    func removeProject(_ id: ProjectID) async throws

    /// Creates an agent and sends its first message.
    func launchAgent(_ request: LaunchRequest) async throws -> AgentID
    /// Sends a message, with any attachments, to an existing agent.
    func sendMessage(_ text: String, attachments: [Attachment], to agent: AgentID, delivery: MessageDelivery) async throws
    /// Stops the agent's active run.
    func interrupt(_ agent: AgentID) async throws
    func respond(to request: RequestID, of agent: AgentID, decision: ApprovalDecision) async throws
    /// Answers a user-input request. `answers` maps question IDs to answer text.
    func answer(request: RequestID, of agent: AgentID, answers: [String: String]) async throws

    func archive(_ agent: AgentID) async throws
    func unarchive(_ agent: AgentID) async throws
    func delete(_ agent: AgentID) async throws
    func rename(_ agent: AgentID, title: String) async throws
    func setRuntimeMode(_ mode: RuntimeMode, for agent: AgentID) async throws
    /// Records that the user looked at the agent, which clears its unseen result.
    func markVisited(_ agent: AgentID) async

    /// The agent's conversation. The stream starts with a `.reset` and stays
    /// live until the consumer cancels it.
    func conversation(for agent: AgentID) -> AsyncStream<ConversationEvent>

    /// Everything the agent changed, as unified diff text.
    func diff(for agent: AgentID) async throws -> String

    /// The output of a `.command` row, which the conversation stream may leave
    /// out. `itemID` is the row's `TimelineItem.id`.
    func commandOutput(for agent: AgentID, itemID: String) async throws -> String?
}

extension AgentBackend {
    /// Sends a message that carries no attachments.
    public func sendMessage(_ text: String, to agent: AgentID, delivery: MessageDelivery) async throws {
        try await sendMessage(text, attachments: [], to: agent, delivery: delivery)
    }
}
