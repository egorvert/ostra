import Foundation

/// One file's changes, parsed from unified diff text.
public struct FileDiff: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case added
        case modified
        case deleted
        case renamed
    }

    public struct Line: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case context
            case addition
            case deletion
        }

        public var kind: Kind
        public var oldNumber: Int?
        public var newNumber: Int?
        public var text: String
    }

    public struct Hunk: Identifiable, Hashable, Sendable {
        public var id: Int
        public var header: String
        public var lines: [Line]
    }

    public var path: String
    public var oldPath: String?
    public var kind: Kind
    public var isBinary: Bool
    public var hunks: [Hunk]

    public var id: String { path }

    public var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .addition }) }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .deletion }) }
    }
}

public enum UnifiedDiff {
    /// Parses `git diff` output into per-file changes. Text that isn't a diff yields no files.
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: FileDiff.Hunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }

        func closeFile() {
            closeHunk()
            if let finished = current { files.append(finished) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("diff --git ") {
                closeFile()
                let paths = gitHeaderPaths(line)
                current = FileDiff(
                    path: paths.new ?? paths.old ?? "",
                    oldPath: nil,
                    kind: .modified,
                    isBinary: false,
                    hunks: []
                )
                continue
            }

            guard current != nil else { continue }

            if hunk == nil {
                if line.hasPrefix("new file mode") {
                    current?.kind = .added
                } else if line.hasPrefix("deleted file mode") {
                    current?.kind = .deleted
                } else if line.hasPrefix("rename from ") {
                    current?.kind = .renamed
                    current?.oldPath = String(line.dropFirst("rename from ".count))
                } else if line.hasPrefix("rename to ") {
                    current?.path = String(line.dropFirst("rename to ".count))
                } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    current?.isBinary = true
                } else if line.hasPrefix("+++ ") {
                    let path = stripPrefix(String(line.dropFirst(4)))
                    if path != "/dev/null" { current?.path = path }
                } else if line.hasPrefix("--- ") {
                    let path = stripPrefix(String(line.dropFirst(4)))
                    if path == "/dev/null" { current?.kind = .added }
                }
            }

            if line.hasPrefix("@@") {
                closeHunk()
                let range = hunkRange(line)
                oldLine = range.old
                newLine = range.new
                hunk = FileDiff.Hunk(id: current?.hunks.count ?? 0, header: line, lines: [])
                continue
            }

            guard hunk != nil else { continue }

            if line.hasPrefix("+") {
                hunk?.lines.append(.init(kind: .addition, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunk?.lines.append(.init(kind: .deletion, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                hunk?.lines.append(.init(kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            } else if line.isEmpty {
                // A context line whose single space was stripped, or the trailing split artifact.
                continue
            }
            // "\ No newline at end of file" and other markers carry no content.
        }
        closeFile()
        return files
    }

    /// Totals across files.
    public static func stats(_ files: [FileDiff]) -> ChangeStats {
        ChangeStats(
            files: files.count,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions }
        )
    }

    private static func stripPrefix(_ path: String) -> String {
        var result = path
        if let tab = result.firstIndex(of: "\t") { result = String(result[..<tab]) }
        if result.hasPrefix("a/") || result.hasPrefix("b/") { result = String(result.dropFirst(2)) }
        return result
    }

    private static func gitHeaderPaths(_ line: String) -> (old: String?, new: String?) {
        // "diff --git a/path b/path". Paths with spaces make the split ambiguous,
        // so the "+++" and "rename to" lines override this when present.
        let body = line.dropFirst("diff --git ".count)
        guard let separator = body.range(of: " b/") else { return (nil, nil) }
        let old = stripPrefix(String(body[..<separator.lowerBound]))
        let new = String(body[separator.upperBound...])
        return (old, new)
    }

    private static func hunkRange(_ header: String) -> (old: Int, new: Int) {
        // "@@ -12,7 +12,9 @@ optional section"
        var old = 0
        var new = 0
        for token in header.split(separator: " ") {
            if token.hasPrefix("-"), let value = Int(token.dropFirst().split(separator: ",").first ?? "") {
                old = value
            } else if token.hasPrefix("+"), let value = Int(token.dropFirst().split(separator: ",").first ?? "") {
                new = value
            }
        }
        return (old, new)
    }
}
