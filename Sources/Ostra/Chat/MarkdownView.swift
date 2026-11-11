import AppKit
import OstraCore
import SwiftUI

/// Renders Markdown as native text blocks.
struct MarkdownView: View {
    var text: String
    var size: CGFloat = 13.5

    var body: some View {
        let blocks = Markdown.blocks(text)
        VStack(alignment: .leading, spacing: size * 0.72) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(Self.inline(text, size: size))
                .font(Theme.text(size))
                .lineSpacing(size * 0.26)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            Text(Self.inline(text, size: size))
                .font(Theme.text(size + CGFloat(max(0, 4 - level)) * 1.6, .semibold))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 3 : 0)

        case let .code(language, text):
            CodeBlock(language: language, text: text, size: size - 1)

        case let .list(items, _):
            VStack(alignment: .leading, spacing: size * 0.34) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(for: item)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(item.text, size: size))
                            .font(Theme.text(size))
                            .lineSpacing(size * 0.22)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 3)
                Text(Self.inline(text, size: size))
                    .font(Theme.text(size))
                    .foregroundStyle(.secondary)
                    .lineSpacing(size * 0.22)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .table(header, rows):
            MarkdownTable(header: header, rows: rows, size: size - 0.5)

        case .rule:
            Hairline().padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownBlock.ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: size - 1.5))
                .foregroundStyle(checked ? Theme.accent : Color.secondary)
        } else if let marker = item.marker {
            Text(marker)
                .font(Theme.text(size).monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .font(Theme.text(size, .bold))
                .foregroundStyle(.tertiary)
        }
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

/// A fenced code block with a copy button.
struct CodeBlock: View {
    var language: String?
    var text: String
    var size: CGFloat

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text.isEmpty ? " " : text)
                .font(Theme.mono(size))
                .lineSpacing(size * 0.3)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(copied ? Theme.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.pressable)
            .padding(6)
            .opacity(hovering || copied ? 1 : 0)
            .animation(Motion.hover, value: hovering)
            .help("Copy")
        }
        .onHover { hovering = $0 }
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
