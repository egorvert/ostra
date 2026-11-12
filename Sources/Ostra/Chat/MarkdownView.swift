import AppKit
import OstraCore
import SwiftUI

/// Renders Markdown as native text blocks.
///
/// Paragraphs, headings, lists, and quotes that sit together draw as one
/// `SelectableText`, so a reader can select across them. Code blocks,
/// tables, and rules draw as views of their own between those runs.
struct MarkdownView: View {
    var text: String
    var size: CGFloat = 13.5

    private enum Segment {
        case text([MarkdownBlock])
        case code(language: String?, text: String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    var body: some View {
        let segments = Self.segments(Markdown.blocks(text))
        VStack(alignment: .leading, spacing: size * 0.72) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(blocks):
                    SelectableText(text: RichText.blocks(blocks, size: size))
                case let .code(language, text):
                    CodeBlock(language: language, text: text, size: size - 1)
                case let .table(header, rows):
                    MarkdownTable(header: header, rows: rows, size: size - 0.5)
                case .rule:
                    Hairline().padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var segments: [Segment] = []
        var run: [MarkdownBlock] = []
        func flush() {
            if !run.isEmpty { segments.append(.text(run)) }
            run = []
        }
        for block in blocks {
            switch block {
            case let .code(language, text):
                flush()
                segments.append(.code(language: language, text: text))
            case let .table(header, rows):
                flush()
                segments.append(.table(header: header, rows: rows))
            case .rule:
                flush()
                segments.append(.rule)
            case .paragraph, .heading, .list, .quote:
                run.append(block)
            }
        }
        flush()
        return segments
    }

    /// Styles inline Markdown: emphasis, links, and code spans.
    static func inline(_ source: String, size: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var result = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            result[run.range].font = Fonts.mono(size - 1)
            result[run.range].backgroundColor = Color.primary.opacity(0.07)
        }
        return result
    }
}

/// A fenced code block: a slim header with the language and a copy button, then the code.
struct CodeBlock: View {
    var language: String?
    var text: String
    var size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language)
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    CopyButton(text: text)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .frame(height: 30)
                Hairline()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(Theme.mono(size))
                    .lineSpacing(size * 0.32)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            // Blocks without a header keep the copy button in the corner.
            if language == nil || language?.isEmpty == true {
                CopyButton(text: text)
                    .padding(4)
            }
        }
    }
}

private struct MarkdownTable: View {
    var header: [String]
    var rows: [[String]]
    var size: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownView.inline(cell, size: size))
                            .font(Theme.text(size, .semibold))
                    }
                }
                Hairline().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownView.inline(cell, size: size))
                                .font(Theme.text(size))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }
}
