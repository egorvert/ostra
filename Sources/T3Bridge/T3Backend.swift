import Foundation
import OstraCore

/// Settings for the local T3 Code engine.
public struct T3Configuration: Sendable {
    /// The pinned T3 Code release.
    public var version: String
    /// Where Ostra keeps the engine runtime, its data directory, and its credentials.
    public var supportDirectory: URL
    /// Where release archives come from.
    public var releaseBaseURL: URL

    public init(
        version: String = "0.1.8",
        supportDirectory: URL = T3Configuration.defaultSupportDirectory,
        releaseBaseURL: URL = URL(string: "https://github.com/pingdotgg/t3code/releases/download")!
    ) {
        self.version = version
        self.supportDirectory = supportDirectory
        self.releaseBaseURL = releaseBaseURL
    }

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ostra", isDirectory: true)
    }
}
