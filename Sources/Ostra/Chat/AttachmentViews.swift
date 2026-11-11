import AppKit
import OstraCore
import SwiftUI

/// One attachment: a thumbnail for an image, and a labeled tile for anything else.
struct AttachmentChip: View {
    let attachment: Attachment
    /// The tile's height. Images are square; files are as wide as their label.
    var size: CGFloat = 48
    /// Shows a remove button on hover. The chat box passes it; the conversation doesn't.
    var onRemove: (() -> Void)?

    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button {
            app.openAttachment(attachment)
        } label: {
            Group {
                if attachment.kind == .image {
                    AttachmentThumbnail(path: attachment.path, size: size)
                        .frame(width: size, height: size)
                } else {
                    label
                }
            }
            .background { shape.fill(Color.primary.opacity(0.06)) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75) }
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .overlay(alignment: .topTrailing) {
            if let onRemove, hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                        .contentShape(Circle().inset(by: -4))
                }
                .buttonStyle(.pressable)
                .offset(x: 5, y: -5)
                .transition(AnyTransition(Materialize(scale: 0.8)).animation(Motion.popIn))
                .help("Remove")
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(attachment.kind == .image ? attachment.name : "\(attachment.name) · \(attachment.sizeLabel)")
        .accessibilityLabel("\(attachment.name), \(attachment.sizeLabel)")
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.kind == .text ? "text.alignleft" : "doc")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.kind == .text ? "Pasted text" : attachment.name)
                    .font(Theme.ui(12, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.sizeLabel)
                    .font(Theme.text(11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: size)
        .frame(maxWidth: 190, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// An image attachment's preview. It fades in when the decode finishes.
private struct AttachmentThumbnail: View {
    var path: String?
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: path) {
            guard let path else { return }
            if let cached = Thumbnails.shared.cached(path, size: size) {
                image = cached
                return
            }
            let loaded = await Thumbnails.shared.load(path, size: size)
            withAnimation(Motion.hover) { image = loaded }
        }
    }
}

/// The row of attachments on the draft, above the text.
struct AttachmentTray: View {
    var attachments: [Attachment]
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) { app.removeAttachment(attachment.id) }
                        .transition(.chip)
                }
            }
            // Room for the remove buttons, which sit on the tiles' corners.
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }
}

/// The attachments of a sent message, above its bubble.
struct MessageAttachments: View {
    var attachments: [Attachment]

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind != .image }
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { AttachmentChip(attachment: $0, size: images.count == 1 ? 120 : 72) }
                }
            }
            ForEach(files) { AttachmentChip(attachment: $0, size: 40) }
        }
    }
}
