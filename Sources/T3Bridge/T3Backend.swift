import Foundation
import OstraCore

/// An `AgentBackend` that drives a local T3 Code server.
///
/// `T3Backend` installs the pinned T3 Code release when it's missing, runs the
/// server on a loopback port with its own data directory, and talks to it over
/// the server's JSON WebSocket RPC. The app sees only the `AgentBackend`
/// protocol.
public final class T3Backend: AgentBackend {
    private let engine: T3Engine

    public init(configuration: T3Configuration = .init()) {
        engine = T3Engine(configuration: configuration)
    }

    public func events() -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream<BackendEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        continuation.onTermination = { [engine] _ in
            Task { await engine.removeSubscriber(id) }
        }
        Task { [engine] in await engine.addSubscriber(id, continuation) }
        return stream
    }

    public func start() async {
        await engine.start()
    }

    public func shutdown() async {
        await engine.shutdown()
    }

    public func addProject(path: String, title: String?) async throws -> Project {
        try await engine.addProject(path: path, title: title)
    }

    /// Removes a project that has no agents. The engine refuses a project that
    /// still has agents; use `removeProject(_:force:)` to delete them with it.
    public func removeProject(_ id: ProjectID) async throws {
        try await engine.removeProject(id, force: false)
    }

    /// Removes a project. With `force`, the engine also deletes the project's
    /// agents and their conversations. Files on disk stay.
    public func removeProject(_ id: ProjectID, force: Bool) async throws {
        try await engine.removeProject(id, force: force)
    }

    public func launchAgent(_ request: LaunchRequest) async throws -> AgentID {
        try await engine.launchAgent(request)
    }

    public func sendMessage(_ text: String, to agent: AgentID, delivery: MessageDelivery) async throws {
        try await engine.dispatch(T3Commands.dispatchMessage(threadID: agent.rawValue, text: text, delivery: delivery))
    }

    public func interrupt(_ agent: AgentID) async throws {
        try await engine.dispatch(T3Commands.stopThread(threadID: agent.rawValue))
    }

    public func respond(to request: RequestID, of agent: AgentID, decision: ApprovalDecision) async throws {
        try await engine.dispatch(
            T3Commands.respond(threadID: agent.rawValue, requestID: request.rawValue, decision: decision)
        )
    }

    /// Answers a user-input request.
    ///
    /// For a question that allows several selections, put one selection on
    /// each line of the answer text.
    public func answer(request: RequestID, of agent: AgentID, answers: [String: String]) async throws {
        try await engine.answer(request: request, thread: agent.rawValue, answers: answers)
    }

    public func archive(_ agent: AgentID) async throws {
        try await engine.archive(thread: agent.rawValue)
    }

    public func unarchive(_ agent: AgentID) async throws {
        try await engine.dispatch(T3Commands.unarchive(threadID: agent.rawValue))
    }

    public func delete(_ agent: AgentID) async throws {
        try await engine.dispatch(T3Commands.delete(threadID: agent.rawValue))
    }

    public func rename(_ agent: AgentID, title: String) async throws {
        try await engine.dispatch(T3Commands.rename(threadID: agent.rawValue, title: title))
    }

    public func setRuntimeMode(_ mode: RuntimeMode, for agent: AgentID) async throws {
        try await engine.dispatch(T3Commands.setRuntimeMode(threadID: agent.rawValue, mode: mode))
    }

    public func markVisited(_ agent: AgentID) async {
        try? await engine.dispatch(T3Commands.visit(threadID: agent.rawValue))
    }

    public func conversation(for agent: AgentID) -> AsyncStream<ConversationEvent> {
        let (stream, continuation) = AsyncStream<ConversationEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let threadID = agent.rawValue
        continuation.onTermination = { [engine] _ in
            Task { await engine.removeConsumer(id, thread: threadID) }
        }
        Task { [engine] in await engine.addConsumer(id, thread: threadID, continuation) }
        return stream
    }

    public func diff(for agent: AgentID) async throws -> String {
        try await engine.diff(thread: agent.rawValue)
    }

    /// The output of a command row. The conversation stream leaves command
    /// output out, so the UI fetches it when the user expands a row.
    ///
    /// - Parameter itemID: The `TimelineItem.id` of a `.command` row.
    /// - Returns: The output, or nil when the engine has none.
    public func commandOutput(for agent: AgentID, itemID: String) async throws -> String? {
        try await engine.commandOutput(thread: agent.rawValue, itemID: itemID)
    }
}
