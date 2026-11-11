import Darwin
import Foundation
import OstraCore

/// Where a running T3 server listens.
struct ServerEndpoint: Sendable, Hashable {
    var port: Int

    var httpBase: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func webSocketURL(ticket: String) -> URL {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "orchestrationProtocol", value: "2"),
            URLQueryItem(name: "wsTicket", value: ticket),
        ]
        return components.url!
    }
}

/// What the server's descriptor endpoint says about it.
struct ServerDescriptor: Sendable, Hashable {
    var version: String
    var environmentID: String
}

/// The record Ostra keeps of the server it runs, so a later launch can attach to it.
struct ServerRecord: Sendable, Hashable {
    var pid: Int32
    var port: Int
    var version: String
    var environmentID: String?

    init(pid: Int32, port: Int, version: String, environmentID: String?) {
        self.pid = pid
        self.port = port
        self.version = version
        self.environmentID = environmentID
    }

    init?(json: JSONValue) {
        guard let pid = json.int("pid"), let port = json.int("port"), let version = json.string("version") else {
            return nil
        }
        self.init(pid: Int32(pid), port: port, version: version, environmentID: json.string("environmentId"))
    }

    var json: JSONValue {
        var members: [String: JSONValue] = [
            "pid": .number(Double(pid)),
            "port": .number(Double(port)),
            "version": .string(version),
        ]
        if let environmentID { members["environmentId"] = .string(environmentID) }
        return .object(members)
    }
}

/// Starts, finds, and stops the local T3 server.
actor ServerSupervisor {
    private let configuration: T3Configuration
    /// The child process, when this supervisor spawned the server.
    private var child: Process?
    /// The server this supervisor manages: a child, or a verified server from an earlier launch.
    private var managedPID: Int32?
    private var endpoint: ServerEndpoint?
    /// The exit status of the child, once it exits.
    private var childExitStatus: Int32?
    private var resolvedPath: String?

    /// The exit status a T3 server uses when another server owns its data directory.
    private static let exitStatusStateDirectoryOwned: Int32 = 78

    init(configuration: T3Configuration) {
        self.configuration = configuration
    }

    /// Returns a live server for the configured data directory.
    ///
    /// Reuses the current server when it still answers, attaches to a server
    /// that an earlier launch left running, or spawns a new one.
    func ensureRunning(binary: URL) async throws -> ServerEndpoint {
        if let endpoint, await Self.probe(endpoint) != nil {
            return endpoint
        }
        endpoint = nil

        if let attached = await attachToRecordedServer() {
            endpoint = attached
            return attached
        }
        let spawned = try await spawn(binary: binary)
        endpoint = spawned
        return spawned
    }

    /// Stops the managed server. Sends `SIGTERM`, then `SIGKILL` if the server lingers.
    func stop() async {
        defer {
            child = nil
            managedPID = nil
            endpoint = nil
            try? FileManager.default.removeItem(at: configuration.serverRecordFile)
        }
        guard let pid = managedPID else { return }
        if let child {
            if child.isRunning { child.terminate() }
        } else if Self.isT3Process(pid) {
            kill(pid, SIGTERM)
        } else {
            return
        }
        if await Self.waitForExit(of: pid, timeout: .seconds(4)) { return }
        kill(pid, SIGKILL)
        _ = await Self.waitForExit(of: pid, timeout: .seconds(2))
    }

    // MARK: - Attaching

    private func attachToRecordedServer() async -> ServerEndpoint? {
        for record in recordedServers() {
            guard Self.isT3Process(record.pid) else { continue }
            let candidate = ServerEndpoint(port: record.port)
            guard let descriptor = await Self.probe(candidate), descriptor.version == configuration.version else {
                continue
            }
            if let expected = record.environmentID, expected != descriptor.environmentID { continue }
            managedPID = record.pid
            child = nil
            childExitStatus = nil
            writeRecord(
                ServerRecord(
                    pid: record.pid,
                    port: record.port,
                    version: descriptor.version,
                    environmentID: descriptor.environmentID
                )
            )
            return candidate
        }
        return nil
    }

    /// The servers that might own the data directory: Ostra's own record first,
    /// then the runtime state that the T3 server writes while it runs.
    private func recordedServers() -> [ServerRecord] {
        var records: [ServerRecord] = []
        if let data = try? Data(contentsOf: configuration.serverRecordFile),
            let json = try? JSONValue.parse(data),
            let record = ServerRecord(json: json)
        {
            records.append(record)
        }
        let runtimeState = configuration.homeDirectory.appendingPathComponent("userdata/server-runtime.json")
        if let data = try? Data(contentsOf: runtimeState),
            let json = try? JSONValue.parse(data),
            let pid = json.int("pid"),
            let port = json.int("port"),
            json.string("host") == nil || json.string("host") == "127.0.0.1"
        {
            let version = json.string("serverVersion") ?? configuration.version
            records.append(ServerRecord(pid: Int32(pid), port: port, version: version, environmentID: nil))
        }
        return records
    }

    private func writeRecord(_ record: ServerRecord) {
        let file = configuration.serverRecordFile
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(record.json.serialized(sortedKeys: true).utf8).write(to: file, options: .atomic)
    }

    // MARK: - Spawning

    private func spawn(binary: URL) async throws -> ServerEndpoint {
        let fileManager = FileManager.default
        let home = configuration.homeDirectory
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)

        let logFile = configuration.serverLogFile
        try fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile)

        let port = try Self.freePort()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve", "--host", "127.0.0.1", "--port", String(port), "--base-dir", home.path]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.environment = await serverEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            let status = finished.terminationStatus
            Task { await self?.childDidExit(pid: pid, status: status) }
        }
        childExitStatus = nil
        do {
            try process.run()
        } catch {
            try? log.close()
            throw BackendError("Couldn't start the T3 Code engine: \(error.localizedDescription)")
        }
        try? log.close()
        child = process
        managedPID = process.processIdentifier

        let candidate = ServerEndpoint(port: port)
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let descriptor = await Self.probe(candidate) {
                writeRecord(
                    ServerRecord(
                        pid: process.processIdentifier,
                        port: port,
                        version: descriptor.version,
                        environmentID: descriptor.environmentID
                    )
                )
                return candidate
            }
            if let status = childExitStatus {
                child = nil
                managedPID = nil
                if status == Self.exitStatusStateDirectoryOwned, let attached = await attachToRecordedServer() {
                    return attached
                }
                throw BackendError("The T3 Code engine exited during startup (status \(status)). \(logTail())")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw BackendError("The T3 Code engine didn't become ready in time. \(logTail())")
    }

    private func childDidExit(pid: Int32, status: Int32) {
        guard child?.processIdentifier == pid else { return }
        childExitStatus = status
    }

    private func logTail() -> String {
        guard let data = try? Data(contentsOf: configuration.serverLogFile) else { return "" }
        let text = String(decoding: data.suffix(1_500), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).suffix(6).joined(separator: " | ")
        return lines.isEmpty ? "" : "Log: \(lines)"
    }

    /// The environment for the server. An app that Finder launches gets a
    /// minimal `PATH`, so this adds the login shell's `PATH` and the usual tool
    /// directories. Provider CLIs such as `codex` and `claude` resolve from it.
    private func serverEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if resolvedPath == nil {
            resolvedPath = await Self.resolvePath(current: environment["PATH"])
        }
        environment["PATH"] = resolvedPath
        environment["T3CODE_HOME"] = configuration.homeDirectory.path
        return environment
    }

    static func resolvePath(current: String?) async -> String {
        let home = NSHomeDirectory()
        var entries: [String] = []
        if let shellPath = await loginShellPath() { entries += shellPath.split(separator: ":").map(String.init) }
        if let current { entries += current.split(separator: ":").map(String.init) }
        entries += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return mergePathEntries(entries)
    }

    /// Joins `PATH` entries, keeping the first occurrence of each directory.
    static func mergePathEntries(_ entries: [String]) -> String {
        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Asks the user's login shell for its `PATH`.
    private static func loginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let marker = "__OSTRA_PATH__"
        guard
            let result = try? await ProcessRunner.run(
                URL(fileURLWithPath: shell),
                arguments: ["-ilc", "printf '%s%s%s' '\(marker)' \"$PATH\" '\(marker)'"],
                timeout: .seconds(5)
            ),
            result.status == 0
        else { return nil }
        let parts = result.stdout.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    // MARK: - Probing

    /// Reads the server's descriptor. Returns nil when nothing answers.
    static func probe(_ endpoint: ServerEndpoint) async -> ServerDescriptor? {
        var request = URLRequest(url: endpoint.httpBase.appendingPathComponent(".well-known/t3/environment"))
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONValue.parse(data),
            let version = json.string("serverVersion"),
            let environmentID = json.string("environmentId")
        else { return nil }
        return ServerDescriptor(version: version, environmentID: environmentID)
    }

    /// Asks the system for a free loopback port.
    static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BackendError("Couldn't open a socket to find a free port.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw BackendError("Couldn't find a free port for the engine.") }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw BackendError("Couldn't find a free port for the engine.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// True when `pid` is a live process whose executable is named `t3`.
    static func isT3Process(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent == "t3"
    }

    private static func waitForExit(of pid: Int32, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            // A child that exited stays a zombie until reaped, so check the path, not the signal.
            if !isT3Process(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isT3Process(pid)
    }
}
