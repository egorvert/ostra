import AppKit
import OstraCore
import SwiftUI
import UniformTypeIdentifiers

/// Attachments on the draft: files, images, and long pasted text.
///
/// Files on disk stay where they are, and the attachment points at them.
/// Content that has no file yet (a screenshot on the clipboard, a block of
/// pasted text) goes into the staging folder first.
extension AppModel {
    /// What the current draft carries.
    var attachments: [Attachment] {
        get { draftAttachments[draftKey] ?? [] }
        set { draftAttachments[draftKey] = newValue.isEmpty ? nil : newValue }
    }

    // MARK: - Adding

    /// Attaches files from disk. Folders can't travel with a message, so
    /// their paths go into the text instead.
    func attach(urls: [URL]) {
        var folders: [String] = []
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                folders.append(url.path)
            } else if let attachment = AttachmentStaging.attachment(forFile: url) {
                add(attachment)
            } else {
                store.toast(.init(kind: .error, text: "Couldn't read \(url.lastPathComponent)."))
            }
        }
        if !folders.isEmpty {
            insertIntoDraft(folders.joined(separator: "\n"))
        }
    }

    /// Attaches image data that has no file, such as a screenshot on the clipboard.
    func attach(imageData: Data, name: String = "Pasted image") {
        guard let attachment = AttachmentStaging.stageImage(imageData, name: name) else {
            store.toast(.init(kind: .error, text: "Couldn't read the image."))
            return
        }
        add(attachment)
    }

    /// Attaches a long block of text as a file, so the message stays readable.
    func attach(text: String) {
        guard let attachment = AttachmentStaging.stageText(text) else { return }
        add(attachment)
    }

    private func add(_ attachment: Attachment) {
        var list = attachments
        if let path = attachment.path, list.contains(where: { $0.path == path }) { return }
        guard list.count < AttachmentLimits.maxCount else {
            store.toast(.init(kind: .error, text: "A message carries up to \(AttachmentLimits.maxCount) attachments."))
            return
        }
        let limit = attachment.kind == .image ? AttachmentLimits.maxImageBytes : AttachmentLimits.maxFileBytes
        guard attachment.byteCount <= limit else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            store.toast(.init(kind: .error, text: "\(attachment.name) is larger than \(size)."))
            return
        }
        list.append(attachment)
        Motion.perform(Motion.snappy) { attachments = list }
    }

    func removeAttachment(_ id: String) {
        Motion.perform(Motion.snappy) {
            attachments.removeAll { $0.id == id }
        }
    }

    /// Adds text at the end of the draft, on its own line when the draft has text.
    func insertIntoDraft(_ text: String) {
        guard !text.isEmpty else { return }
        if let view = focus.chatInput, view.window?.firstResponder === view {
            view.insertText(text, replacementRange: view.selectedRange())
            return
        }
        let current = draft
        draft = current.isEmpty || current.hasSuffix("\n") || current.hasSuffix(" ") ? current + text : current + " " + text
    }

    // MARK: - Sources

    /// Opens the file picker.
    func chooseAttachments() {
        closeOverlay()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose files or images to send with the message."
        if let project = store.selectedAgent?.snapshot.workingDirectory ?? store.currentProject?.path {
            panel.directoryURL = URL(fileURLWithPath: project)
        }
        if panel.runModal() == .OK {
            attach(urls: panel.urls)
            focus.focusChat()
        }
    }

    /// Takes what the pasteboard holds that isn't short plain text: files,
    /// images, and long text. Returns false when the caller should paste text.
    @discardableResult
    func attachFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            attach(urls: urls)
            return true
        }

        let types = pasteboard.types ?? []
        let text = pasteboard.string(forType: .string)
        let imageType = [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
            .first { types.contains($0) }
        // Rich text from a document often carries a picture of itself. The
        // text is what the user copied.
        let isRichText = types.contains(.rtf) || types.contains(.html)
        if let imageType, text == nil || !isRichText, let data = pasteboard.data(forType: imageType) {
            attach(imageData: data)
            return true
        }
        if types.contains(.pdf), text == nil, let data = pasteboard.data(forType: .pdf),
           let attachment = AttachmentStaging.stage(data, name: "Pasted document.pdf", mimeType: "application/pdf", kind: .file) {
            add(attachment)
            return true
        }
        if let text, text.count > AttachmentLimits.pastedTextThreshold {
            attach(text: text)
            return true
        }
        return false
    }

    /// Pastes the clipboard into the draft while the chat box doesn't have the keyboard.
    func pasteIntoDraft() {
        if attachFromPasteboard() {
            focus.focusChat()
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        insertIntoDraft(text)
        focus.focusChat()
    }

    /// Takes what was dropped on the window.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.attach(urls: [url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                let name = provider.suggestedName ?? "Dropped image"
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.attach(imageData: data, name: name) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in
                        if text.count > AttachmentLimits.pastedTextThreshold {
                            self.attach(text: text)
                        } else {
                            self.insertIntoDraft(text)
                        }
                    }
                }
            }
        }
        if handled { focus.focusChat() }
        return handled
    }

    /// Opens an attachment in the app that handles its type.
    func openAttachment(_ attachment: Attachment) {
        guard let path = attachment.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// Turns files and loose content into attachments.
enum AttachmentStaging {
    /// Where content without a file of its own is kept.
    static var directory: URL {
        Runtime.options.supportDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// The image formats every engine accepts as they are.
    private static let directImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// An attachment for a file on disk. Images in formats the engines don't
    /// take, such as HEIC or TIFF, are converted to PNG in the staging folder.
    static func attachment(forFile url: URL) -> Attachment? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let size = values?.fileSize ?? 0

        if let type, type.conforms(to: .image), type != .svg {
            if directImageTypes.contains(mime) {
                return Attachment(kind: .image, name: url.lastPathComponent, mimeType: mime, byteCount: size, path: url.path)
            }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return stageImage(data, name: url.deletingPathExtension().lastPathComponent)
        }
        guard size > 0 else { return nil }
        return Attachment(kind: .file, name: url.lastPathComponent, mimeType: mime, byteCount: size, path: url.path)
    }

    /// Saves image data as a PNG, or as it is when it's already a format engines take.
    static func stageImage(_ data: Data, name: String) -> Attachment? {
        let base = (name as NSString).deletingPathExtension
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier), let mime = type.preferredMIMEType, directImageTypes.contains(mime),
           let fileExtension = type.preferredFilenameExtension {
            return stage(data, name: "\(base).\(fileExtension)", mimeType: mime, kind: .image)
        }
        guard let image = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let png = image.representation(using: .png, properties: [:]) else { return nil }
        return stage(png, name: "\(base).png", mimeType: "image/png", kind: .image)
    }

    static func stageText(_ text: String) -> Attachment? {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return nil }
        return stage(data, name: "Pasted text.txt", mimeType: "text/plain", kind: .text)
    }

    /// Writes `data` into its own folder, so files with the same name never collide.
    static func stage(_ data: Data, name: String, mimeType: String, kind: Attachment.Kind) -> Attachment? {
        let id = UUID().uuidString.lowercased()
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return Attachment(id: id, kind: kind, name: name, mimeType: mimeType, byteCount: data.count, path: file.path)
    }

    /// Removes staged content that's older than `days`. Conversations keep
    /// their own copies in the engine, so old staging is safe to drop.
    nonisolated static func prune(olderThan days: Int = 30, in directory: URL) {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}

/// Loads small previews of image attachments, once per file.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ path: String, size: CGFloat) -> NSImage? {
        cache.object(forKey: "\(path)#\(Int(size))" as NSString)
    }

    /// Decodes a preview that fits `size` points, off the main thread.
    func load(_ path: String, size: CGFloat) async -> NSImage? {
        if let image = cached(path, size: size) { return image }
        let pixels = size * 2
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width / 2, height: cgImage.height / 2))
        cache.setObject(image, forKey: "\(path)#\(Int(size))" as NSString)
        return image
    }
}
