import AppKit
import OstraCore
import SwiftUI

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
        return AppModel(store: store, settings: AppSettings())
    }()
}

/// What the command line and the environment ask for.
struct LaunchOptions {
    /// True to run on the simulated engine.
    var demo: Bool
    /// Steps for `DebugScript`, used to drive the UI in development.
    var script: String?

    init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        demo = arguments.contains("--demo") || environment["OSTRA_DEMO"] == "1"
        script = environment["OSTRA_SCRIPT"]
    }

    var supportDirectory: URL {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary runs outside an app bundle during development.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Runtime.model.start()
        if let script = Runtime.options.script {
            DebugScript(model: Runtime.model).run(script)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }
        isShuttingDown = true
        // Give the engine a moment to stop its processes, but never hang the quit.
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await Runtime.model.store.shutdown() }
                group.addTask { try? await Task.sleep(for: .seconds(4)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum Backends {
    static func make(_ options: LaunchOptions) -> any AgentBackend {
        MockBackend()
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
                case "quit":
                    NSApp.terminate(nil)
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
