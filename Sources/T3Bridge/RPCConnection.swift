import Foundation

/// A failure of an RPC call or of the socket that carries it.
public struct RPCError: Error, LocalizedError, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The socket closed before the call finished.
        case disconnected
        /// The server answered with a typed failure.
        case failure
        /// The server reported a defect or a protocol error.
        case defect
        /// The call didn't finish in time.
        case timeout
    }

    public var kind: Kind
    public var message: String
    /// The `_tag` of the server's error, when the server sent one.
    public var tag: String?

    public init(kind: Kind, message: String, tag: String? = nil) {
        self.kind = kind
        self.message = message
        self.tag = tag
    }

    public var errorDescription: String? { message }
}

/// The Effect RPC wire frames that the T3 server speaks over its JSON WebSocket.
enum RPCFrame {
    static func request(id: String, tag: String, payload: JSONValue) -> JSONValue {
        ["_tag": "Request", "id": .string(id), "tag": .string(tag), "payload": payload, "headers": []]
    }

    static func ack(requestID: String) -> JSONValue {
        ["_tag": "Ack", "requestId": .string(requestID)]
    }

    static func interrupt(requestID: String) -> JSONValue {
        ["_tag": "Interrupt", "requestId": .string(requestID)]
    }

    /// A server frame, reduced to what the client acts on.
    enum Inbound: Equatable {
        case chunk(requestID: String, values: [JSONValue])
        case success(requestID: String, value: JSONValue)
        case failure(requestID: String, error: RPCError)
        /// A socket-level defect. It ends every pending request.
        case defect(message: String)
        case pong
        case unknown
    }

    /// Splits a socket message into frames. The server sends one frame per
    /// message, but the protocol allows an array.
    static func decode(_ message: JSONValue) -> [Inbound] {
        if case .array(let frames) = message { return frames.map(decodeOne) }
        return [decodeOne(message)]
    }

    private static func decodeOne(_ frame: JSONValue) -> Inbound {
        switch frame.string("_tag") {
        case "Chunk":
            guard let id = frame.string("requestId") else { return .unknown }
            return .chunk(requestID: id, values: frame.array("values"))
        case "Exit":
            guard let id = frame.string("requestId"), let exit = frame["exit"] else { return .unknown }
            if exit.string("_tag") == "Success" {
                return .success(requestID: id, value: exit["value"] ?? .null)
            }
            return .failure(requestID: id, error: describeFailure(exit))
        case "Defect":
            return .defect(message: describe(frame["defect"]) ?? "The server reported a defect.")
        case "ClientProtocolError":
            return .defect(message: describe(frame["error"]) ?? "The server rejected a frame.")
        case "Pong":
            return .pong
        default:
            return .unknown
        }
    }

    /// Reads a failed `Exit`. The cause is a list of `Fail`, `Die`, and
    /// `Interrupt` entries; older encodings nest a single object instead.
    private static func describeFailure(_ exit: JSONValue) -> RPCError {
        var entries: [JSONValue] = []
        if let cause = exit["cause"] {
            if case .array(let list) = cause { entries = list } else { entries = [cause] }
        }
        for entry in entries {
            switch entry.string("_tag") {
            case "Fail":
                let error = entry["error"] ?? .null
                return RPCError(
                    kind: .failure,
                    message: describe(error) ?? "The request failed.",
                    tag: error.string("_tag")
                )
            case "Die":
                return RPCError(kind: .defect, message: describe(entry["defect"]) ?? "The server hit a defect.")
            case "Interrupt":
                return RPCError(kind: .failure, message: "The request was interrupted.", tag: "Interrupt")
            default:
                continue
            }
        }
        return RPCError(kind: .failure, message: describe(exit["cause"]) ?? "The request failed.")
    }

    /// Pulls readable text out of an error payload.
    private static func describe(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if let text = value.stringValue { return text }
        if let message = value.nonEmptyString("message") {
            if let detail = value.nonEmptyString("detail"), detail != message {
                return "\(message) \(detail)"
            }
            return message
        }
        if let tag = value.string("_tag") { return tag }
        return value.serialized()
    }
}

/// One WebSocket connection to the T3 server that carries Effect RPC calls.
///
/// The connection doesn't reconnect. When the socket closes, every pending
/// call and stream fails with `.disconnected`, and the owner builds a new one.
actor RPCConnection {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var nextID = 0
    private var calls: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var closed = false
    private var closeReason: RPCError?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var receiveLoop: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private let outbox: AsyncStream<String>.Continuation
    private let outboxStream: AsyncStream<String>
    private var writer: Task<Void, Never>?

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        self.session = session
        let task = session.webSocketTask(with: url)
        // Snapshots of long threads run to many megabytes in one frame.
        task.maximumMessageSize = 512 * 1024 * 1024
        self.task = task
        (outboxStream, outbox) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Opens the socket and starts the read and write loops.
    func open(timeout: Duration = .seconds(10)) async throws {
        task.resume()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [task] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // The pong only arrives once the upgrade handshake succeeded.
                    task.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RPCError(kind: .timeout, message: "The engine socket didn't open in time.")
            }
            defer { group.cancelAll() }
            do {
                try await group.next()
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                throw error
            }
        }

        // The loops run detached so socket I/O and JSON parsing stay off the actor.
        writer = Task.detached { [weak self, task, outboxStream] in
            for await text in outboxStream {
                do {
                    try await task.send(.string(text))
                } catch {
                    await self?.didClose(RPCError(kind: .disconnected, message: error.localizedDescription))
                    return
                }
            }
        }
        receiveLoop = Task.detached { [weak self, task] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    // A large snapshot takes a while to parse; other calls keep flowing meanwhile.
                    guard let parsed = try? JSONValue.parse(data) else { continue }
                    await self?.handle(RPCFrame.decode(parsed))
                } catch {
                    await self?.didClose(RPCError(kind: .disconnected, message: error.localizedDescription))
                    return
                }
            }
        }
        keepAlive = Task.detached { [weak self, task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { return }
                let alive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    task.sendPing { error in continuation.resume(returning: error == nil) }
                }
                if !alive {
                    await self?.didClose(RPCError(kind: .disconnected, message: "The engine stopped answering."))
                    return
                }
            }
        }
    }

    /// Runs a request that returns one value.
    func call(_ tag: String, _ payload: JSONValue = [:], timeout: Duration = .seconds(120)) async throws -> JSONValue {
        if closed { throw closeReason ?? RPCError(kind: .disconnected, message: "The engine connection is closed.") }
        let id = allocateID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if Task.isCancelled { return }
            await self?.expire(id, tag: tag)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            calls[id] = continuation
            send(RPCFrame.request(id: id, tag: tag, payload: payload))
        }
    }

    /// Runs a streaming request. The stream fails with `.disconnected` when the
    /// socket closes. Cancelling the consumer interrupts the request.
    nonisolated func stream(_ tag: String, _ payload: JSONValue = [:]) -> AsyncThrowingStream<JSONValue, Error> {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .unbounded)
        Task { await self.startStream(tag: tag, payload: payload, continuation: continuation) }
        return stream
    }

    /// Closes the socket and fails everything that's pending.
    func close() {
        didClose(RPCError(kind: .disconnected, message: "The engine connection closed."))
    }

    /// Returns when the socket has closed, for any reason.
    func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    var isClosed: Bool { closed }

    // MARK: - Internals

    private func allocateID() -> String {
        defer { nextID += 1 }
        return String(nextID)
    }

    private func send(_ frame: JSONValue) {
        outbox.yield(frame.serialized())
    }

    private func startStream(
        tag: String,
        payload: JSONValue,
        continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    ) {
        if closed {
            continuation.finish(
                throwing: closeReason ?? RPCError(kind: .disconnected, message: "The engine connection is closed.")
            )
            return
        }
        let id = allocateID()
        streams[id] = continuation
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancelStream(id) }
        }
        send(RPCFrame.request(id: id, tag: tag, payload: payload))
    }

    private func cancelStream(_ id: String) {
        guard streams.removeValue(forKey: id) != nil, !closed else { return }
        send(RPCFrame.interrupt(requestID: id))
    }

    private func expire(_ id: String, tag: String) {
        guard let continuation = calls.removeValue(forKey: id) else { return }
        send(RPCFrame.interrupt(requestID: id))
        continuation.resume(throwing: RPCError(kind: .timeout, message: "The engine didn't answer \(tag) in time."))
    }

    private func handle(_ frames: [RPCFrame.Inbound]) {
        for frame in frames {
            switch frame {
            case .chunk(let id, let values):
                // The server waits for the acknowledgement before it sends the next chunk.
                send(RPCFrame.ack(requestID: id))
                if let stream = streams[id] {
                    for value in values { stream.yield(value) }
                }
            case .success(let id, let value):
                if let call = calls.removeValue(forKey: id) {
                    call.resume(returning: value)
                } else if let stream = streams.removeValue(forKey: id) {
                    stream.finish()
                }
            case .failure(let id, let error):
                if let call = calls.removeValue(forKey: id) {
                    call.resume(throwing: error)
                } else if let stream = streams.removeValue(forKey: id) {
                    stream.finish(throwing: error)
                }
            case .defect(let message):
                didClose(RPCError(kind: .defect, message: message))
            case .pong, .unknown:
                break
            }
        }
    }

    private func didClose(_ reason: RPCError) {
        guard !closed else { return }
        closed = true
        closeReason = reason
        receiveLoop?.cancel()
        keepAlive?.cancel()
        outbox.finish()
        writer?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        let pendingCalls = calls
        calls.removeAll()
        for (_, call) in pendingCalls { call.resume(throwing: reason) }
        let pendingStreams = streams
        streams.removeAll()
        for (_, stream) in pendingStreams { stream.finish(throwing: reason) }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
