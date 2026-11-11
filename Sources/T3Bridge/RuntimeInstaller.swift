import CryptoKit
import Foundation
import OstraCore
import Synchronization

/// Installs the pinned T3 Code release under the support directory.
///
/// The layout matches the upstream launcher: one directory per version, written
/// to a staging directory first and renamed into place once it's complete.
struct RuntimeInstaller: Sendable {
    let configuration: T3Configuration

    /// The directory that holds the release for the pinned version.
    var versionDirectory: URL {
        configuration.supportDirectory
            .appendingPathComponent("runtime/versions", isDirectory: true)
            .appendingPathComponent(configuration.version, isDirectory: true)
    }

    private var completionMarker: URL { versionDirectory.appendingPathComponent(".install-complete") }

    /// The release asset for this machine.
    static var platformKey: String {
        #if arch(arm64)
        "darwin-arm64"
        #else
        "darwin-x64"
        #endif
    }

    /// Returns the `t3` binary, installing the release first when it's missing.
    ///
    /// - Parameter progress: Receives a message and, during the download, a
    ///   fraction from 0 to 1.
    func ensureInstalled(progress: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        if let override = configuration.binaryOverride {
            guard FileManager.default.isExecutableFile(atPath: override.path) else {
                throw BackendError("The engine binary at \(override.path) doesn't exist or isn't executable.")
            }
            return override
        }

        let binary = versionDirectory.appendingPathComponent("t3")
        if isComplete, FileManager.default.isExecutableFile(atPath: binary.path) {
            return binary
        }

        #if !arch(arm64)
        throw BackendError("T3 Code \(configuration.version) has no macOS build for Intel processors.")
        #else
        try await install(progress: progress)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw BackendError("The T3 Code \(configuration.version) archive doesn't contain the engine binary.")
        }
        return binary
        #endif
    }

    private var isComplete: Bool {
        guard let text = try? String(contentsOf: completionMarker, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == configuration.version
    }

    private func install(progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let fileManager = FileManager.default
        let version = configuration.version
        let archiveName = "t3-\(version)-\(Self.platformKey).tar.gz"
        let releaseURL = configuration.releaseBaseURL.appendingPathComponent("v\(version)")

        progress("Checking T3 Code \(version)", nil)
        let expected = try await expectedChecksum(for: archiveName, at: releaseURL)

        let parent = versionDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("\(version).staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(archiveName)
        let actual = try await download(
            releaseURL.appendingPathComponent(archiveName),
            to: archive,
            progress: { fraction in progress("Downloading T3 Code \(version)", fraction) }
        )
        guard actual == expected else {
            throw BackendError("The T3 Code \(version) download is corrupt: its checksum doesn't match the release.")
        }

        progress("Unpacking T3 Code \(version)", nil)
        try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", staging.path, "--strip-components=1"],
            timeout: .seconds(300)
        ).requireSuccess("Couldn't unpack T3 Code \(version)")
        try fileManager.removeItem(at: archive)

        let binary = staging.appendingPathComponent("t3")
        let check = try await ProcessRunner.run(binary, arguments: ["--version"], timeout: .seconds(30))
        try check.requireSuccess("T3 Code \(version) doesn't run on this Mac")

        try Data("\(version)\n".utf8).write(to: staging.appendingPathComponent(".install-complete"))
        // Replace a half-installed directory, but keep one that a parallel install finished.
        if fileManager.fileExists(atPath: versionDirectory.path) {
            if isComplete { return }
            try fileManager.removeItem(at: versionDirectory)
        }
        try fileManager.moveItem(at: staging, to: versionDirectory)
    }

    private func expectedChecksum(for archiveName: String, at releaseURL: URL) async throws -> String {
        let url = releaseURL.appendingPathComponent("SHA256SUMS")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BackendError("Couldn't read the T3 Code \(configuration.version) release checksums.")
        }
        guard let checksum = Self.checksum(for: archiveName, in: String(decoding: data, as: UTF8.self)) else {
            throw BackendError("The T3 Code \(configuration.version) release doesn't list \(archiveName).")
        }
        return checksum
    }

    /// Finds the SHA-256 for `archiveName` in a `SHA256SUMS` file.
    static func checksum(for archiveName: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            var name = String(parts[parts.count - 1])
            if name.hasPrefix("*") { name.removeFirst() }
            let hash = String(parts[0]).lowercased()
            if name == archiveName, hash.count == 64, hash.allSatisfy(\.isHexDigit) {
                return hash
            }
        }
        return nil
    }

    /// Downloads `url` to `destination` and returns the SHA-256 of the file.
    private func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> String {
        let version = configuration.version
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(destination: destination, onProgress: progress) { failure in
                if let failure {
                    continuation.resume(throwing: BackendError("Couldn't download T3 Code \(version): \(failure)"))
                } else {
                    continuation.resume()
                }
            }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
        return try Self.sha256(of: destination)
    }

    /// Hashes a file in chunks so a large archive never sits in memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Moves a finished download into place and reports progress on the way.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var failure: String?
        var lastPercent = -1
        var finished = false
    }

    private let destination: URL
    private let onProgress: @Sendable (Double?) -> Void
    /// Receives nil on success, or the reason the download failed.
    private let completion: @Sendable (String?) -> Void
    private let state = Mutex(State())

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Double?) -> Void,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            onProgress(nil)
            return
        }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        let changed = state.withLock { state -> Bool in
            guard state.lastPercent != percent else { return false }
            state.lastPercent = percent
            return true
        }
        if changed { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file disappears when this method returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw BackendError("the release server answered HTTP \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            let message = error.localizedDescription
            state.withLock { $0.failure = message }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transportFailure = error?.localizedDescription
        let outcome = state.withLock { state -> (finished: Bool, failure: String?) in
            guard !state.finished else { return (false, nil) }
            state.finished = true
            return (true, transportFailure ?? state.failure)
        }
        if outcome.finished { completion(outcome.failure) }
    }
}

/// Runs a short-lived child process and collects its output.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String

        func requireSuccess(_ context: String) throws {
            guard status == 0 else {
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BackendError(detail.isEmpty ? "\(context)." : "\(context): \(detail)")
            }
        }
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes while the process runs so a chatty child can't fill a pipe and stall.
        async let output = readAll(stdout.fileHandleForReading)
        async let errors = readAll(stderr.fileHandleForReading)

        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            exited.continuation.yield()
            exited.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            _ = await (output, errors)
            throw BackendError("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)")
        }

        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
        for await _ in exited.stream {}
        watchdog.cancel()

        let (outData, errData) = await (output, errors)
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
