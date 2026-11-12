import AppKit
import OstraCore
import SwiftUI

/// Text the reader can select and copy, drawn by one `NSTextView`.
///
/// SwiftUI's `textSelection` selects inside a single `Text`, so a drag can't
/// cross from one paragraph to the next, and a drag that starts beside a
/// short line selects nothing. A message renders as one text view instead:
/// a drag runs across its paragraphs, lists, and quotes, and can start
/// anywhere in the row.
struct SelectableText: NSViewRepresentable {
    var text: NSAttributedString
    /// True to take the whole width offered, so a drag can start right of a
    /// short line. False to hug the text, as a message bubble does.
    var fillsWidth = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView.make()
        view.textStorage?.setAttributedString(text)
        return view
    }

    func updateNSView(_ view: TranscriptTextView, context: Context) {
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        // Keep a selection the reader made while the text streams in.
        let selection = view.selectedRange()
        storage.setAttributedString(text)
        if NSMaxRange(selection) <= storage.length { view.setSelectedRange(selection) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptTextView, context: Context) -> CGSize? {
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 100_000
        let used = context.coordinator.size(of: text, width: offered)
        return CGSize(width: fillsWidth && offered < 100_000 ? offered : min(offered, used.width), height: used.height)
    }

    /// Measures text off screen, and remembers the answers for the current text.
    final class Coordinator {
        private var measured: NSAttributedString?
        private var sizes: [CGFloat: CGSize] = [:]

        func size(of text: NSAttributedString, width: CGFloat) -> CGSize {
            if measured !== text, measured?.isEqual(to: text) != true {
                measured = text
                sizes = [:]
            }
            if let size = sizes[width] { return size }
            let size = Self.measure(text, width: width)
            sizes[width] = size
            return size
        }

        static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            // A point of slack keeps a hugging view from wrapping its last word.
            return CGSize(width: ceil(used.width) + 1, height: ceil(used.height))
        }
    }
}

/// The text view behind `SelectableText`: read-only, transparent, and
/// polite about the keyboard and the scroll wheel.
final class TranscriptTextView: NSTextView {
    static func make() -> TranscriptTextView {
        // TextKit 1, so the view lays out exactly as the measurement does.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let view = TranscriptTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.usesFontPanel = false
        view.focusRingType = .none
        // The selection lights the background only; text keeps its own
        // colors, so quiet markers stay quiet.
        view.selectedTextAttributes = view.selectedTextAttributes.filter { $0.key != .foregroundColor }
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Theme.accent),
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    /// One selection at a time: leaving a message clears the one in it.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }

    /// A drag starts selecting even when the window wasn't active, as
    /// SwiftUI's own selectable text does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The conversation scrolls, not the message.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Builds the attributed text for `SelectableText` from Markdown.
enum RichText {
    /// Plain text, such as the user's own message.
    static func plain(_ text: String, size: CGFloat, lineSpacing: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return NSAttributedString(string: text, attributes: [
            .font: Fonts.nsSans(size),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    /// Paragraphs, headings, lists, and quotes as one run of text. The space
    /// between blocks matches `MarkdownView`'s stack, so nothing shifts.
    static func blocks(_ blocks: [MarkdownBlock], size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blockGap = size * 0.72

        func append(_ line: NSAttributedString, spacing: CGFloat) {
            if result.length > 0 {
                // The line break belongs to the paragraph before it, so it takes its style.
                let previous = result.attributes(at: result.length - 1, effectiveRange: nil)
                result.append(NSAttributedString(string: "\n", attributes: previous))
            }
            let start = result.length
            result.append(line)
            let range = NSRange(location: start, length: result.length - start)
            result.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.paragraphSpacing = spacing
                result.addAttribute(.paragraphStyle, value: style, range: subrange)
            }
        }

        for block in blocks {
            switch block {
            case let .paragraph(text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = size * 0.26
                append(inline(text, size: size, style: style), spacing: blockGap)

            case let .heading(level, text):
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = level <= 2 ? 3 : 0
                let headingSize = size + CGFloat(max(0, 4 - level)) * 1.6
                append(inline(text, size: headingSize, weight: .semibold, style: style), spacing: blockGap)

            case let .list(items, _):
                for (index, item) in items.enumerated() {
                    let last = index == items.count - 1
                    append(listItem(item, size: size), spacing: last ? blockGap : size * 0.34)
                }

            case let .quote(text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = size * 0.22
                let block = NSTextBlock()
                block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                block.setBorderColor(dynamic(light: NSColor(white: 0, alpha: 0.18), dark: NSColor(white: 1, alpha: 0.18)), for: .minX)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                style.textBlocks = [block]
                append(inline(text, size: size, color: .secondaryLabelColor, style: style), spacing: blockGap)

            case .code, .table, .rule:
                // These draw as views of their own, between runs of text.
                continue
            }
        }

        // The stack around the run spaces it from its neighbors.
        if result.length > 0 {
            let lastParagraph = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 0))
            result.enumerateAttribute(.paragraphStyle, in: lastParagraph) { value, subrange, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.paragraphSpacing = 0
                result.addAttribute(.paragraphStyle, value: style, range: subrange)
            }
        }
        return result
    }

    /// A list item: the marker in a narrow column, then text that wraps under itself.
    private static func listItem(_ item: MarkdownBlock.ListItem, size: CGFloat) -> NSAttributedString {
        let indent = CGFloat(item.depth) * 16
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.22
        style.firstLineHeadIndent = indent
        style.headIndent = indent + 21
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: indent + 14),
            NSTextTab(textAlignment: .left, location: indent + 21),
        ]
        let line = NSMutableAttributedString(string: "\t", attributes: [.font: Fonts.nsSans(size), .paragraphStyle: style])

        if let checked = item.checked {
            let symbol = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square", accessibilityDescription: checked ? "Done" : "To do")
            let color = checked ? NSColor(Theme.accent) : NSColor.secondaryLabelColor
            let configured = symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size - 1.5, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            )
            let attachment = NSTextAttachment()
            attachment.image = configured
            if let image = configured {
                let font = Fonts.nsSans(size)
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            }
            line.append(NSAttributedString(attachment: attachment))
        } else if let marker = item.marker {
            line.append(NSAttributedString(string: marker, attributes: [
                .font: Fonts.nsSans(size),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        } else {
            line.append(NSAttributedString(string: "•", attributes: [
                .font: Fonts.nsSans(size, .bold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        line.append(NSAttributedString(string: "\t", attributes: [.font: Fonts.nsSans(size)]))
        line.append(inline(item.text, size: size, style: style))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// Styles inline Markdown: emphasis, strong text, links, and code spans.
    static func inline(
        _ source: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: NSColor = .labelColor,
        style: NSParagraphStyle
    ) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .font: Fonts.nsSans(size, intent.contains(.stronglyEmphasized) ? .semibold : weight),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            if intent.contains(.code) {
                attributes[.font] = Fonts.nsMono(size - 1)
                attributes[.backgroundColor] = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.07))
            }
            if intent.contains(.emphasized) {
                // Geist has no italic face, so emphasis slants the regular one.
                attributes[.obliqueness] = 0.14
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// A color that follows the view's appearance when it draws.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
