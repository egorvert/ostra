import AppKit
import SwiftUI

/// The chat box's editor: a text view that grows with its content.
///
/// Return sends, and Shift-Return or Option-Return adds a line. An
/// `NSTextView` gives exact control over those keys and over focus, which
/// the modal keyboard depends on.
struct ChatTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var font: NSFont = .systemFont(ofSize: 14)
    var maxLines = 9
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void
    /// Offers the pasteboard to the app first. Returns true when the app took
    /// it as attachments, and false to paste plain text.
    var onPaste: () -> Bool = { false }
    /// Hands the text view to the focus coordinator.
    var register: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let textView = FocusReportingTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.focusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        textView.pasteAttachments = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPaste() ?? false
        }
        // Drops belong to the window, which turns files into attachments.
        textView.unregisterDraggedTypes()
        textView.string = text
        scroll.documentView = textView
        register(textView)
        DispatchQueue.main.async { context.coordinator.measure(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.measure(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextView

        init(_ parent: ChatTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            measure(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        /// Reports the height the text needs, capped at `maxLines`.
        func measure(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: parent.font)
            let used = layout.usedRect(for: container).height
            let height = min(max(used, line), line * CGFloat(parent.maxLines)).rounded(.up)
            guard abs(height - parent.height) > 0.5 else { return }
            DispatchQueue.main.async { [parent] in
                parent.height = height
            }
        }
    }
}

/// A text view that reports when it gains and loses the keyboard.
final class FocusReportingTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    var pasteAttachments: (() -> Bool)?

    /// Files, images, and long text become attachments. Everything else
    /// pastes as plain text, so no foreign fonts or colors come along.
    override func paste(_ sender: Any?) {
        if pasteAttachments?() == true { return }
        pasteAsPlainText(sender)
    }

    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
}
