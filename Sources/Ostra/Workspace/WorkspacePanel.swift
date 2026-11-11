import AppKit
import OstraCore
import SwiftTerm
import SwiftUI

/// The left panel: tools that follow the selected agent.
///
/// The panel is a host, not a diff viewer. Each tool is one case of
/// `WorkspaceTool`, so adding a tool means adding a case and a view.
struct WorkspacePanel: View {
    @Environment(AppModel.self) private var app
    @State private var resizeStart: CGFloat?

    var body: some View {
        let agent = app.store.selectedAgent
        VStack(spacing: 0) {
            header(agent)
            Hairline()
            content(agent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassPanel(cornerRadius: Theme.panelRadius, frost: app.settings.data.chatFrost)
        .overlay(alignment: .trailing) { resizeHandle }
        .hudRegion("workspace", in: app.hudRegions)
    }

    private func header(_ agent: AgentModel?) -> some View {
        HStack(spacing: 10) {
            TextTabs(items: WorkspaceTool.allCases, selection: app.workspaceTool, label: \.label) {
                app.setWorkspaceTool($0)
            }
            Spacer(minLength: 6)
            if let agent {
                HStack(spacing: 7) {
                    StatusDot(phase: agent.phase, unseen: false, size: 7)
                    Text(agent.name)
                        .font(Theme.ui(12, .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            QuietIconButton(symbol: "xmark", help: "Close (C)") { app.toggleWorkspace(animated: true) }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    @ViewBuilder
    private func content(_ agent: AgentModel?) -> some View {
        let directory = agent?.snapshot.workingDirectory ?? app.store.currentProject?.path
        switch app.workspaceTool {
        case .diff:
            if let agent {
                DiffView(agent: agent).id(agent.id)
            } else {
                emptyState("Select an agent to see its changes.")
            }
        case .files:
            if let directory {
                FilesView(root: directory).id(directory)
            } else {
                emptyState("Add a project folder to browse files.")
            }
        case .terminal:
            if let directory {
                TerminalPane(directory: directory)
                    .id(directory)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                emptyState("Add a project folder to open a terminal.")
            }
        case .activity:
            if let agent {
                ActivityView(agent: agent).id(agent.id)
            } else {
                emptyState("Select an agent to see its activity.")
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(Theme.text(12.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Dragging the panel's right edge resizes it.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStart ?? app.workspaceWidth
                        resizeStart = start
                        let limit = max(380, app.viewSize.width - 420)
                        Motion.instantly {
                            app.workspaceWidth = min(max(380, start + value.translation.width), limit)
                        }
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }
}

// MARK: - Files

/// A lazily loaded file tree with a read-only viewer underneath.
struct FilesView: View {
    let root: String
    @State private var tree = FileTree()
    @State private var selected: String?

    var body: some View {
        let rows = tree.rows(root: root)
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text("No files in this folder")
                    .font(Theme.text(12.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        FileRowView(row: row, selected: row.path == selected)
                            .onTapGesture {
                                if row.isDirectory {
                                    withAnimation(Motion.snappy) { tree.toggle(row.path) }
                                } else {
                                    selected = row.path
                                }
                            }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: rows.isEmpty ? 0 : (selected == nil ? .infinity : 230))

            if let selected {
                Hairline()
                FileViewer(path: selected, root: root) { self.selected = nil }
                    .id(selected)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

struct FileRow: Identifiable {
    var path: String
    var name: String
    var depth: Int
    var isDirectory: Bool
    var isExpanded: Bool
    var id: String { path }
}

/// Lists directories on demand and remembers which ones are open.
@Observable
final class FileTree {
    private var expanded: Set<String> = []
    @ObservationIgnored private var cache: [String: [(name: String, isDirectory: Bool)]] = [:]

    /// Folders that are large and rarely worth browsing.
    private static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".next", "dist", ".swiftpm", ".DS_Store"]

    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    func rows(root: String) -> [FileRow] {
        var rows: [FileRow] = []
        append(directory: root, depth: 0, to: &rows)
        return rows
    }

    private func append(directory: String, depth: Int, to rows: inout [FileRow]) {
        guard depth < 24, rows.count < 5000 else { return }
        for entry in children(of: directory) {
            let path = (directory as NSString).appendingPathComponent(entry.name)
            let open = entry.isDirectory && expanded.contains(path)
            rows.append(FileRow(path: path, name: entry.name, depth: depth, isDirectory: entry.isDirectory, isExpanded: open))
            if open { append(directory: path, depth: depth + 1, to: &rows) }
        }
    }

    private func children(of directory: String) -> [(name: String, isDirectory: Bool)] {
        if let cached = cache[directory] { return cached }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
        let entries = names
            .filter { !Self.skipped.contains($0) }
            .map { name -> (name: String, isDirectory: Bool) in
                var isDirectory: ObjCBool = false
                manager.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
                return (name, isDirectory.boolValue)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        cache[directory] = entries
        return entries
    }
}

private struct FileRowView: View {
    let row: FileRow
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .opacity(row.isDirectory ? 1 : 0)
                .frame(width: 10)
            Image(systemName: row.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 10.5))
                .foregroundStyle(row.isDirectory ? Theme.accent.opacity(0.8) : Color.secondary)
                .frame(width: 15)
            Text(row.name)
                .font(Theme.text(12))
                .foregroundStyle(row.name.hasPrefix(".") ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 4)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.10 : (hovering ? 0.05 : 0)))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Shows a text file with line numbers, or an image.
private struct FileViewer: View {
    let path: String
    let root: String
    var onClose: () -> Void

    @State private var content: Loaded = .loading

    enum Loaded {
        case loading
        case text([Substring], truncated: Bool)
        case image(NSImage)
        case unreadable(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(relativePath)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.pressable)
                .help("Show in Finder")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.pressable)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)

            switch content {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unreadable(message):
                Text(message)
                    .font(Theme.text(12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .image(image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .text(lines, truncated):
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(line.isEmpty ? " " : String(line))
                                    .textSelection(.enabled)
                                    .fixedSize()
                            }
                            .font(Theme.mono(11.5))
                            .frame(height: 17)
                        }
                        if truncated {
                            Text("The file is larger than the viewer shows.")
                                .font(Theme.text(11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 46)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 14)
                }
            }
        }
        .task(id: path) { content = await Self.load(path) }
    }

    private var relativePath: String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    private static func load(_ path: String) async -> Loaded {
        await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "icns"]
            if imageTypes.contains(url.pathExtension.lowercased()), let image = NSImage(contentsOf: url) {
                return Loaded.image(image)
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return .unreadable("Couldn't open the file.")
            }
            defer { try? handle.close() }
            let limit = 400_000
            let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
            if data.prefix(4096).contains(0) { return .unreadable("Binary file") }
            let truncated = data.count > limit
            guard let text = String(data: data.prefix(limit), encoding: .utf8)
                ?? String(data: data.prefix(limit), encoding: .isoLatin1) else {
                return .unreadable("The file isn't text.")
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6000)
            return .text(Array(lines), truncated: truncated || lines.count == 6000)
        }.value
    }
}

// MARK: - Terminal

/// Keeps one shell per directory alive while the app runs, so switching
/// tools or agents doesn't end the session.
final class TerminalSessions {
    static let shared = TerminalSessions()
    private var views: [String: LocalProcessTerminalView] = [:]
    private var dark = false

    func view(for directory: String) -> LocalProcessTerminalView {
        if let existing = views[directory] { return existing }
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        terminal.font = Fonts.nsMono(12)
        terminal.caretColor = NSColor(Theme.accent)
        style(terminal)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: directory
        )
        views[directory] = terminal
        return terminal
    }

    /// Matches every terminal to the app's color scheme.
    func setDark(_ dark: Bool) {
        guard dark != self.dark else { return }
        self.dark = dark
        for view in views.values { style(view) }
    }

    func terminateAll() {
        for view in views.values { view.terminate() }
        views.removeAll()
    }

    /// The terminal draws straight onto the glass panel, so its colors follow the panel's.
    private func style(_ terminal: LocalProcessTerminalView) {
        terminal.nativeBackgroundColor = .clear
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        terminal.nativeForegroundColor = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.13, alpha: 1)
        terminal.installColors(Self.palette(dark: dark))
    }

    /// Sixteen ANSI colors that keep their contrast on a light or a dark panel.
    private static func palette(dark: Bool) -> [SwiftTerm.Color] {
        let light: [(Int, Int, Int)] = [
            (38, 38, 38), (196, 45, 45), (30, 128, 64), (166, 110, 10),
            (28, 100, 220), (150, 62, 190), (16, 128, 140), (120, 120, 120),
            (90, 90, 90), (224, 70, 70), (40, 154, 82), (190, 130, 16),
            (52, 124, 240), (176, 88, 214), (24, 150, 162), (60, 60, 60),
        ]
        let night: [(Int, Int, Int)] = [
            (60, 62, 68), (240, 108, 108), (112, 208, 140), (236, 196, 104),
            (112, 168, 255), (204, 148, 240), (104, 208, 220), (200, 200, 204),
            (128, 130, 138), (250, 136, 136), (140, 224, 164), (244, 212, 132),
            (144, 188, 255), (220, 172, 248), (136, 222, 232), (240, 240, 242),
        ]
        return (dark ? night : light).map { red, green, blue in
            SwiftTerm.Color(red: UInt16(red * 257), green: UInt16(green * 257), blue: UInt16(blue * 257))
        }
    }
}

/// A shell in the agent's working directory.
struct TerminalPane: NSViewRepresentable {
    let directory: String
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSView {
        TerminalSessions.shared.setDark(scheme == .dark)
        let container = NSView()
        let terminal = TerminalSessions.shared.view(for: directory)
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        TerminalSessions.shared.setDark(scheme == .dark)
    }
}
