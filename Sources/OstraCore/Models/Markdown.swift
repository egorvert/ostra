import Foundation

/// A block of Markdown. The chat view renders blocks; inline styling stays in the text.
public enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case list(items: [ListItem], ordered: Bool)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    public struct ListItem: Hashable, Sendable {
        public var text: String
        /// Nesting depth, starting at 0.
        public var depth: Int
        /// The marker for ordered items, such as "1.".
        public var marker: String?
        /// The state of a task-list item, or nil for a plain item.
        public var checked: Bool?
    }
}

public enum Markdown {
    /// Splits Markdown text into blocks.
    ///
    /// The parser tolerates incomplete input, such as an unclosed code fence,
    /// because the chat view renders text while it streams.
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [MarkdownBlock.ListItem] = []
        var listOrdered = false
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems, ordered: listOrdered))
            listItems.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // Heading.
            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                index += 1
                continue
            }

            // Horizontal rule.
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            // Table: a pipe row followed by a delimiter row.
            if trimmed.contains("|"), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                flushAll()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(tableCells(row))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Quote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            // List item.
            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                if listItems.isEmpty { listOrdered = item.marker != nil }
                listItems.append(item)
                index += 1
                continue
            }

            // Continuation of a list item.
            if !listItems.isEmpty, line.hasPrefix("  ") {
                listItems[listItems.count - 1].text += " " + trimmed
                index += 1
                continue
            }

            flushList()
            flushQuote()
            paragraph.append(trimmed)
            index += 1
        }
        flushAll()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else {
            return false
        }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let depth = width / 2
        let body = line.dropFirst(indent.count)

        var text: Substring
        var marker: String?

        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            text = body.dropFirst(2)
        } else {
            let digits = body.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 4 else { return nil }
            let rest = body.dropFirst(digits.count)
            guard let punctuation = rest.first, punctuation == "." || punctuation == ")",
                  rest.dropFirst().first == " " else { return nil }
            marker = "\(digits)."
            text = rest.dropFirst(2)
        }

        var checked: Bool?
        if text.hasPrefix("[ ] ") {
            checked = false
            text = text.dropFirst(4)
        } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            checked = true
            text = text.dropFirst(4)
        }

        return MarkdownBlock.ListItem(
            text: text.trimmingCharacters(in: .whitespaces),
            depth: min(depth, 6),
            marker: marker,
            checked: checked
        )
    }
}
