import Foundation
import OstraCore

/// Gets the credentials that open the server's RPC socket.
///
/// The flow has two steps. A bearer token identifies Ostra as a client; the
/// server's own CLI issues it against the shared data directory. A short-lived
/// ticket, minted over HTTP with that token, then opens one WebSocket.
struct T3Auth: Sendable {
    let configuration: T3Configuration
    let binary: URL

    enum TicketError: Error {
        /// The server no longer accepts the bearer token.
        case unauthorized
        case failed(String)
    }

    /// Returns a ticket for one WebSocket connection.
    ///
    /// Reuses the cached bearer token, and issues a new one when the server
    /// rejects it.
    func webSocketTicket(for endpoint: ServerEndpoint) async throws -> String {
        if let token = cachedToken() {
            do {
                return try await requestTicket(endpoint: endpoint, token: token)
            } catch TicketError.unauthorized {
                // Fall through and replace the stale token.
            } catch TicketError.failed(let message) {
                throw BackendError(message)
            }
        }
        let token = try await issueToken()
        do {
            return try await requestTicket(endpoint: endpoint, token: token)
        } catch TicketError.unauthorized {
            throw BackendError("The T3 Code engine rejected Ostra's session token.")
        } catch TicketError.failed(let message) {
            throw BackendError(message)
        }
    }

    func cachedToken() -> String? {
        guard let text = try? String(contentsOf: configuration.sessionTokenFile, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Issues a bearer token with the server's CLI and caches it for later launches.
    func issueToken() async throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["T3CODE_HOME"] = configuration.homeDirectory.path
        let result = try await ProcessRunner.run(
            binary,
            arguments: [
                "auth", "session", "issue",
                "--base-dir", configuration.homeDirectory.path,
                "--token-only",
                "--label", "Ostra",
            ],
            environment: environment,
            timeout: .seconds(30)
        )
        try result.requireSuccess("Couldn't issue an engine session token")
        guard let token = Self.extractToken(from: result.stdout) else {
            throw BackendError("The engine didn't print a session token.")
        }
        try store(token)
        return token
    }

    /// The token is the last non-empty line; the CLI can print log lines before it.
    static func extractToken(from output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.contains(" ") }
    }

    private func store(_ token: String) throws {
        let file = configuration.sessionTokenFile
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create the file owner-only before the secret lands in it.
        try? fileManager.removeItem(at: file)
        guard fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BackendError("Couldn't save the engine session token.")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(token.utf8))
    }

    private func requestTicket(endpoint: ServerEndpoint, token: String) async throws -> String {
        var request = URLRequest(url: endpoint.httpBase.appendingPathComponent("api/auth/websocket-ticket"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TicketError.failed("Couldn't reach the T3 Code engine: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw TicketError.failed("The T3 Code engine sent an unreadable response.")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw TicketError.unauthorized }
        guard http.statusCode == 200, let ticket = (try? JSONValue.parse(data))?.string("ticket") else {
            throw TicketError.failed("The T3 Code engine refused a socket ticket (HTTP \(http.statusCode)).")
        }
        return ticket
    }
}
