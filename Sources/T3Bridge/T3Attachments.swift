import Foundation
import OstraCore

/// Translates attachments between Ostra and a T3 server.
///
/// T3 keeps attachment content in its own store. A client asks for an upload
/// URL, posts the bytes to it, and then names the stored attachment in a launch
/// or dispatch command. The server copies the upload into the thread and hands
/// it to the provider: a supported image reaches the model as image input, and
/// every other file reaches it as a path the agent reads.
///
/// The store refuses empty files, files over 50 MB, and anything that isn't a
/// regular file. Those attachments travel as a block of paths at the end of
/// the message text instead, and the mapper turns the block back into
/// attachments.
enum T3Attachments {
    /// The image types the server passes to a model as image input.
    static let nativeImageTypes: Set<String> = ["image/gif", "image/jpeg", "image/png", "image/webp"]
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxFileBytes = 50 * 1024 * 1024

    private static let maxNameLength = 255
    private static let maxMimeTypeLength = 100
    private static let fallbackMimeType = "application/octet-stream"
    private static let pastedTextExtension = ".txt"

    // MARK: - Sending

    /// How one attachment reaches the agent.
    enum Route: Equatable, Sendable {
        /// The server stores the content.
        case upload(Upload)
        /// The server can't store the content. The message text names its path.
        case pathBlock
    }

    /// An attachment as the server's store describes it.
    struct Upload: Equatable, Sendable {
        /// The wire type: `image` or `file`.
        var type: String
        var name: String
        var mimeType: String
        var sizeBytes: Int
        var isPastedText: Bool

        /// The payload of `attachments.createUploadUrl`.
        var uploadURLRequest: JSONValue {
            [
                "type": .string(type),
                "name": .string(name),
                "mimeType": .string(mimeType),
                "sizeBytes": .number(Double(sizeBytes)),
            ]
        }

        /// The entry a launch or dispatch command carries for the stored upload.
        func reference(id: String) -> JSONValue {
            var reference: JSONValue = [
                "type": .string(type),
                "id": .string(id),
                "name": .string(name),
                "mimeType": .string(mimeType),
                "sizeBytes": .number(Double(sizeBytes)),
            ]
            if isPastedText { reference = reference.setting("source", ["_tag": "pasted-text"]) }
            return reference
        }
    }

    /// Chooses how an attachment travels.
    ///
    /// - Parameters:
    ///   - attachment: The attachment to send.
    ///   - byteCount: The size of the file on disk, or nil when `path` isn't a regular file.
    static func route(for attachment: Attachment, byteCount: Int?) -> Route {
        guard let byteCount, byteCount >= 1, byteCount <= maxFileBytes else { return .pathBlock }
        let mimeType = wireMimeType(attachment.mimeType)
        let isNativeImage = attachment.kind == .image
            && nativeImageTypes.contains(mimeType)
            && byteCount <= maxImageBytes
        return .upload(
            Upload(
                type: isNativeImage ? "image" : "file",
                name: wireName(attachment),
                mimeType: mimeType,
                sizeBytes: byteCount,
                isPastedText: attachment.kind == .text
            )
        )
    }

    /// The name the server stores. The server derives the stored file's
    /// extension from it, so pasted text gets `.txt` and the agent sees a text file.
    static func wireName(_ attachment: Attachment) -> String {
        var name = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = attachment.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        }
        if name.isEmpty { name = "Attachment" }
        if attachment.kind == .text, (name as NSString).pathExtension.isEmpty { name += pastedTextExtension }
        guard name.utf16.count > maxNameLength else { return name }
        // Shorten the stem and keep the extension.
        let fileExtension = (name as NSString).pathExtension
        let suffix = fileExtension.isEmpty || fileExtension.utf16.count > 10 ? "" : "." + fileExtension
        var stem = String(name.dropLast(suffix.count))
        while stem.utf16.count + suffix.utf16.count > maxNameLength { stem.removeLast() }
        return stem.trimmingCharacters(in: .whitespaces) + suffix
    }

    static func wireMimeType(_ mimeType: String) -> String {
        let trimmed = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed.utf16.count > maxMimeTypeLength ? fallbackMimeType : trimmed
    }

    /// Posts a file's bytes to an upload URL the server issued.
    static func post(_ file: URL, to url: URL, mimeType: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        } catch {
            throw BackendError("Couldn't upload \(file.lastPathComponent): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendError(
                "The engine refused \(file.lastPathComponent) (HTTP \(status))" + (detail.isEmpty ? "." : ": \(detail)")
            )
        }
    }

    // MARK: - Receiving

    /// Maps a `ChatAttachment` entity to an attachment.
    ///
    /// - Parameters:
    ///   - wire: The entity from a message or a turn item.
    ///   - directory: The server's attachment store, for the local path. Pass
    ///     nil to leave the path out.
    static func attachment(_ wire: JSONValue, directory: URL?) -> Attachment? {
        guard let id = wire.nonEmptyString("id") else { return nil }
        let type = wire.string("type")
        let mimeType = wire.nonEmptyString("mimeType") ?? fallbackMimeType
        let isPastedText = wire.object("source")?.string("_tag") == "pasted-text"
        let kind: Attachment.Kind =
            if type == "image" {
                .image
            } else if isPastedText {
                .text
            } else if type == "file", mimeType.lowercased().hasPrefix("image/") {
                // An image the model can't take as image input travels as a file.
                .image
            } else {
                .file
            }
        var name = wire.nonEmptyString("name") ?? "Attachment"
        // Drop the extension that `wireName` adds to pasted text.
        if isPastedText, name.count > pastedTextExtension.count, name.lowercased().hasSuffix(pastedTextExtension) {
            name = String(name.dropLast(pastedTextExtension.count))
        }
        return Attachment(
            id: id,
            kind: kind,
            name: name,
            mimeType: mimeType,
            byteCount: wire.int("sizeBytes") ?? 0,
            path: directory.flatMap { storedFile(id: id, mimeType: mimeType, in: $0)?.path }
        )
    }

    private static let imageExtensionsByMimeType: [String: String] = [
        "image/avif": "avif", "image/bmp": "bmp", "image/gif": "gif", "image/heic": "heic", "image/heif": "heif",
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png", "image/svg+xml": "svg", "image/tiff": "tiff",
        "image/webp": "webp",
    ]
    private static let idCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )
    /// The extensions the server stores an attachment under when its ID names none.
    private static let storedExtensions = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "ico", "svg", "tiff", "bin",
    ]

    /// Finds an attachment's content in the server's store.
    ///
    /// The server names each file `<id>.<extension>`. A file attachment's ID
    /// ends with its extension; an image's extension follows from its type.
    static func storedFile(id: String, mimeType: String, in directory: URL) -> URL? {
        // The ID becomes a file name, so it must not carry a path.
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(idCharacters.contains) else { return nil }
        var candidates: [String] = []
        if let named = storedExtension(inID: id) {
            candidates = [named]
        } else {
            if let known = imageExtensionsByMimeType[mimeType.lowercased()] { candidates.append(known) }
            candidates += storedExtensions.filter { !candidates.contains($0) }
        }
        for candidate in candidates {
            let file = directory.appendingPathComponent("\(id).\(candidate)")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// The extension an attachment ID names: `<thread>-<uuid>-<extension>`.
    static func storedExtension(inID id: String) -> String? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 7, let last = parts.last, (1...10).contains(last.count) else { return nil }
        // The part before the extension is the last group of the UUID.
        let uuidTail = parts[parts.count - 2]
        guard uuidTail.count == 12, uuidTail.allSatisfy(\.isHexDigit) else { return nil }
        return last.lowercased()
    }

    // MARK: - The path block

    static let blockOpening = "<ostra-attachments>"
    static let blockClosing = "</ostra-attachments>"
    private static let blockNote =
        "The user attached these files to this message. They're on this computer. Read each one from its path."

    /// Appends a block that names the attachments the server can't store.
    static func appendingPathBlock(_ attachments: [Attachment], to text: String) -> String {
        let entries = attachments.compactMap { attachment -> String? in
            guard let path = attachment.path else { return nil }
            let entry: JSONValue = [
                "id": .string(attachment.id),
                "kind": .string(attachment.kind.rawValue),
                "name": .string(attachment.name),
                "mimeType": .string(attachment.mimeType),
                "sizeBytes": .number(Double(attachment.byteCount)),
                "path": .string(path),
            ]
            return entry.serialized(sortedKeys: true)
        }
        guard !entries.isEmpty else { return text }
        let block = ([blockOpening, blockNote] + entries + [blockClosing]).joined(separator: "\n")
        return text.isEmpty ? block : text + "\n\n" + block
    }

    /// Splits message text into the text the user wrote and the attachments
    /// its path block names. Text without a block comes back unchanged.
    static func splittingPathBlock(_ text: String) -> (text: String, attachments: [Attachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(blockClosing),
            let opening = trimmed.range(of: blockOpening, options: .backwards),
            opening.lowerBound == trimmed.startIndex || trimmed[trimmed.index(before: opening.lowerBound)].isNewline
        else { return (text, []) }
        let body = trimmed[opening.upperBound..<trimmed.index(trimmed.endIndex, offsetBy: -blockClosing.count)]
        let attachments = body.split(whereSeparator: \.isNewline).compactMap { line -> Attachment? in
            guard line.hasPrefix("{"), let entry = try? JSONValue.parse(String(line)),
                let path = entry.nonEmptyString("path")
            else { return nil }
            return Attachment(
                id: entry.nonEmptyString("id") ?? path,
                kind: entry.string("kind").flatMap(Attachment.Kind.init(rawValue:)) ?? .file,
                name: entry.nonEmptyString("name") ?? URL(fileURLWithPath: path).lastPathComponent,
                mimeType: entry.nonEmptyString("mimeType") ?? fallbackMimeType,
                byteCount: entry.int("sizeBytes") ?? 0,
                path: path
            )
        }
        guard !attachments.isEmpty else { return (text, []) }
        let remaining = trimmed[..<opening.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (remaining, attachments)
    }
}
