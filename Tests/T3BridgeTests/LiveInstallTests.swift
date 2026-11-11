import Foundation
import OstraCore
import Testing
@testable import T3Bridge

/// Downloads the real release. Set `OSTRA_T3_DOWNLOAD=1` to run it; the archive is about 114 MB.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OSTRA_T3_DOWNLOAD"] == "1"))
struct LiveInstallTests {
    @Test(.timeLimit(.minutes(10)))
    func installsThePinnedRelease() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("ostra-install-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let installer = RuntimeInstaller(configuration: T3Configuration(supportDirectory: support, binaryOverride: nil))

        let (updates, continuation) = AsyncStream<(String, Double?)>.makeStream()
        let collector = Task {
            var seen: [(String, Double?)] = []
            for await update in updates { seen.append(update) }
            return seen
        }
        let binary = try await installer.ensureInstalled { message, progress in
            continuation.yield((message, progress))
        }
        continuation.finish()
        let progress = await collector.value

        #expect(binary.path == installer.versionDirectory.appendingPathComponent("t3").path)
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        let version = try await ProcessRunner.run(binary, arguments: ["--version"], timeout: .seconds(30))
        #expect(version.stdout.contains("0.1.8"))
        // The archive and staging directory are gone; only the version directory remains.
        let versions = installer.versionDirectory.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: versions.path) == ["0.1.8"])

        let messages = progress.map(\.0)
        #expect(messages.first == "Checking T3 Code 0.1.8")
        #expect(messages.contains("Downloading T3 Code 0.1.8"))
        #expect(messages.last == "Unpacking T3 Code 0.1.8")
        let fractions = progress.filter { $0.0.hasPrefix("Downloading") }.compactMap(\.1)
        #expect(fractions.count > 10)
        #expect(fractions == fractions.sorted())
        #expect((fractions.last ?? 0) > 0.99)

        // A second call finds the install and does no work.
        let again = try await installer.ensureInstalled { _, _ in Issue.record("reinstalled a complete release") }
        #expect(again == binary)
    }
}
