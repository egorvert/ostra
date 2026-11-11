import Foundation

/// A file, an image, or a block of pasted text that travels with a message.
///
/// The content always lives in a file on disk. The app stages pasted and
/// dropped content into its own folder before it sends, so an engine can read
/// `path` at any time during the run.
public struct Attachment: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// A picture the model looks at.
        case image
        /// Any other file. The agent reads it from `path` when it needs it.
        case file
        /// Text that was pasted and is too long to sit in the message.
        case text
    }

    public var id: String
    public var kind: Kind
    /// The name to show, such as `screenshot.png` or `Pasted text`.
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    /// Where the content is on disk. Nil when the engine reports an attachment
    /// whose content it can't locate.
    public var path: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: Kind,
        name: String,
        mimeType: String,
        byteCount: Int,
        path: String?
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.path = path
    }

    /// The size in a form people read, such as `48 KB`.
    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// The limits an engine places on what a message can carry.
public enum AttachmentLimits {
    public static let maxCount = 20
    public static let maxImageBytes = 10 * 1024 * 1024
    public static let maxFileBytes = 50 * 1024 * 1024
    /// Pasted text longer than this becomes an attachment instead of message text.
    public static let pastedTextThreshold = 4_000
}
