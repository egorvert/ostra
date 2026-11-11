import AppKit
import OstraCore
import SwiftUI
import T3Bridge

@main
struct OstraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Ostra", id: "main") {
            RootView()
                .environment(Runtime.model)
                .frame(minWidth: 940, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 940)
        .commands {
            // The app routes its own keys, so the default New Window item goes.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Runtime.model.open(.settings, animated: true) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Process-wide objects. The app has one window and one engine.
enum Runtime {
    static let options = LaunchOptions()
    static let model: AppModel = {
        let store = AppStore(backend: Backends.make(options), persistenceURL: options.stateURL)
        return AppModel(store: store, settings: AppSettings(persists: options.script == nil))
    }()
}

/// What the command line and the environment ask for.
struct LaunchOptions {
    /// True to run on the simulated engine.
    var demo: Bool
    /// Steps for `DebugScript`, used to drive the UI in development.
    var script: String?
    /// Replaces the support directory, so development runs don't touch real state.
    var supportOverride: String?

    init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        demo = arguments.contains("--demo") || environment["OSTRA_DEMO"] == "1"
        script = environment["OSTRA_SCRIPT"]
        supportOverride = environment["OSTRA_SUPPORT_DIR"]
    }

    var supportDirectory: URL {
        if let supportOverride, !supportOverride.isEmpty {
            return URL(fileURLWithPath: supportOverride, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ostra", isDirectory: true)
    }

    /// Layout state lives apart for demo mode, so demo agents never mix with real ones.
    var stateURL: URL {
        supportDirectory.appendingPathComponent(demo ? "ui-state-demo.json" : "ui-state.json")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isShuttingDown = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary runs outside an app bundle during development.
        NSApp.setActivationPolicy(.regular)
        // A scripted run stays in the background, so it never takes the
        // keyboard away from whatever the developer is typing in.
        if Runtime.options.script == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        installSignalHandlers()
        Runtime.model.start()
        if let script = Runtime.options.script {
            DebugScript(model: Runtime.model).run(script)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Routes SIGTERM and SIGINT through the normal quit path, so the engine
    /// the app started stops with it.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Runtime.quit() }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }
        isShuttingDown = true
        TerminalSessions.shared.terminateAll()
        // Give the engine a moment to stop its processes, but never hang the quit.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await Runtime.model.store.shutdown()
            reply()
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            reply()
        }
        return .terminateLater
    }
}

extension Runtime {
    /// Quits through the run loop.
    ///
    /// `terminate(_:)` spins a nested run loop while the engine shuts down. If
    /// it's called from a block on the main dispatch queue, that queue stays
    /// busy and the shutdown work, which runs on the main actor, never starts.
    static func quit() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}

enum Backends {
    static func make(_ options: LaunchOptions) -> any AgentBackend {
        if options.demo { return MockBackend() }
        return T3Backend(configuration: T3Configuration(supportDirectory: options.supportDirectory))
    }
}

/// Drives the UI from a script, so states can be reproduced without typing.
///
/// Steps are separated by spaces: `wait:1.5`, `key:tab`, `key:shift+d`,
/// `type:hello_world` (underscores become spaces), and `quit`.
final class DebugScript {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func run(_ script: String) {
        let steps = script.split(separator: " ").map(String.init)
        Task {
            for step in steps {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "wait":
                    try? await Task.sleep(for: .seconds(Double(argument) ?? 0.5))
                case "key":
                    if let press = Self.press(argument) { _ = model.route(press) }
                    try? await Task.sleep(for: .milliseconds(60))
                case "type":
                    model.draft = argument.replacingOccurrences(of: "_", with: " ")
                case "query":
                    model.pickerQuery = argument.replacingOccurrences(of: "_", with: " ")
                case "project":
                    model.store.addProject(path: argument)
                case "model":
                    let parts = argument.split(separator: "/", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        model.store.spawnProviderID = parts[0]
                        model.store.spawnModelID = parts[1]
                    }
                case "send":
                    model.submitDraft()
                case "frost":
                    model.settings.data.chatFrost = Double(argument) ?? 0.5
                case "appearance":
                    model.settings.data.appearance = AppearanceMode(rawValue: argument) ?? .light
                case "image":
                    model.settings.data.backgroundImagePath = argument
                    model.settings.data.canvasStyle = argument.isEmpty ? .dots : .image
                case "tool":
                    if let tool = WorkspaceTool(rawValue: argument) { model.setWorkspaceTool(tool) }
                case "quit":
                    Runtime.quit()
                default:
                    break
                }
            }
        }
    }

    static func press(_ spec: String) -> KeyPress? {
        var tokens = spec.split(separator: "+").map(String.init)
        guard let name = tokens.popLast() else { return nil }
        let key: KeyCode
        switch name {
        case "esc": key = .escape
        case "enter": key = .enter
        case "tab": key = .tab
        case "space": key = .space
        case "delete": key = .delete
        case "up": key = .up
        case "down": key = .down
        case "left": key = .left
        case "right": key = .right
        case "plus": key = .character("+")
        default:
            guard let character = name.first, name.count == 1 else { return nil }
            key = .character(character)
        }
        return KeyPress(
            key: key,
            shift: tokens.contains("shift"),
            control: tokens.contains("ctrl"),
            option: tokens.contains("opt"),
            command: tokens.contains("cmd")
        )
    }
}
