import Foundation

/// Settings for the local T3 Code engine.
public struct T3Configuration: Sendable {
    /// The pinned T3 Code release.
    public var version: String
    /// Where Ostra keeps the engine runtime, its data directory, and its credentials.
    public var supportDirectory: URL
    /// Where release archives come from.
    public var releaseBaseURL: URL
    /// An existing `t3` binary to run instead of the installed release.
    ///
    /// Defaults to the `OSTRA_T3_BINARY` environment variable, which lets
    /// development builds and tests skip the release download.
    public var binaryOverride: URL?

    public init(
        version: String = "0.1.8",
        supportDirectory: URL = T3Configuration.defaultSupportDirectory,
        releaseBaseURL: URL = URL(string: "https://github.com/pingdotgg/t3code/releases/download")!,
        binaryOverride: URL? = T3Configuration.environmentBinaryOverride
    ) {
        self.version = version
        self.supportDirectory = supportDirectory
        self.releaseBaseURL = releaseBaseURL
        self.binaryOverride = binaryOverride
    }

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ostra", isDirectory: true)
    }

    /// The binary that `OSTRA_T3_BINARY` names, when the variable holds an absolute path.
    public static var environmentBinaryOverride: URL? {
        guard let path = ProcessInfo.processInfo.environment["OSTRA_T3_BINARY"], path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// The T3 home directory: the server's database, settings, and worktrees.
    var homeDirectory: URL { supportDirectory.appendingPathComponent("t3-home", isDirectory: true) }
    /// Where the server keeps attachment content, one file per attachment ID.
    var attachmentsDirectory: URL { homeDirectory.appendingPathComponent("userdata/attachments", isDirectory: true) }
    var serverRecordFile: URL { supportDirectory.appendingPathComponent("server.json") }
    var sessionTokenFile: URL { supportDirectory.appendingPathComponent("session-token") }
    var serverLogFile: URL { supportDirectory.appendingPathComponent("logs/t3-server.log") }
}
