import Foundation
import OstraCore
import Testing
@testable import T3Bridge

/// Swift Testing has an `Attachment` type too. These tests mean Ostra's.
typealias Attachment = OstraCore.Attachment

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ostra-attachments-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let screenshot = Attachment(
    id: "a1", kind: .image, name: "screenshot.png", mimeType: "image/png", byteCount: 2_048, path: "/tmp/stage/a1.png"
)
private let notes = Attachment(
    id: "a2", kind: .file, name: "notes.md", mimeType: "text/markdown", byteCount: 512, path: "/tmp/stage/a2.md"
)
private let pasted = Attachment(
    id: "a3", kind: .text, name: "Pasted text", mimeType: "text/plain", byteCount: 9_000, path: "/tmp/stage/a3.txt"
)

@Suite struct AttachmentRouteTests {
    private func upload(_ attachment: Attachment, byteCount: Int?) -> T3Attachments.Upload? {
        if case .upload(let upload) = T3Attachments.route(for: attachment, byteCount: byteCount) { upload } else { nil }
    }

    @Test func supportedImageGoesAsImageInput() {
        #expect(
            upload(screenshot, byteCount: 2_048)
                == .init(type: "image", name: "screenshot.png", mimeType: "image/png", sizeBytes: 2_048, isPastedText: false)
        )
        // The size comes from the file on disk, not from the attachment's own count.
        #expect(upload(screenshot, byteCount: 4_096)?.sizeBytes == 4_096)
        var shouting = screenshot
        shouting.mimeType = " IMAGE/JPEG "
        #expect(upload(shouting, byteCount: 10)?.type == "image")
        #expect(upload(shouting, byteCount: 10)?.mimeType == "image/jpeg")
    }

    @Test func otherImagesGoAsFiles() {
        var heic = screenshot
        heic.name = "photo.heic"
        heic.mimeType = "image/heic"
        #expect(upload(heic, byteCount: 100)?.type == "file")
        // The server takes images up to 10 MB as image input.
        #expect(upload(screenshot, byteCount: T3Attachments.maxImageBytes)?.type == "image")
        #expect(upload(screenshot, byteCount: T3Attachments.maxImageBytes + 1)?.type == "file")
        // A file stays a file, whatever its type says.
        var plain = screenshot
        plain.kind = .file
        #expect(upload(plain, byteCount: 100)?.type == "file")
    }

    @Test func filesAndPastedTextGoAsFiles() {
        #expect(
            upload(notes, byteCount: 512)
                == .init(type: "file", name: "notes.md", mimeType: "text/markdown", sizeBytes: 512, isPastedText: false)
        )
        #expect(
            upload(pasted, byteCount: 9_000)
                == .init(type: "file", name: "Pasted text.txt", mimeType: "text/plain", sizeBytes: 9_000, isPastedText: true)
        )
    }

    @Test func whatTheServerCannotStoreGoesInThePathBlock() {
        #expect(T3Attachments.route(for: notes, byteCount: 0) == .pathBlock)
        #expect(T3Attachments.route(for: notes, byteCount: nil) == .pathBlock)
        #expect(T3Attachments.route(for: notes, byteCount: T3Attachments.maxFileBytes + 1) == .pathBlock)
        #expect(upload(notes, byteCount: T3Attachments.maxFileBytes) != nil)
    }

    @Test func namesAndTypesFitTheServerLimits() {
        var odd = notes
        odd.name = "   "
        #expect(T3Attachments.wireName(odd) == "a2.md")
        odd.path = nil
        #expect(T3Attachments.wireName(odd) == "Attachment")
        odd.name = String(repeating: "n", count: 400) + ".log"
        let shortened = T3Attachments.wireName(odd)
        #expect(shortened.utf16.count == 255)
        #expect(shortened.hasSuffix(".log"))
        var named = pasted
        named.name = "clipboard.md"
        #expect(T3Attachments.wireName(named) == "clipboard.md")

        #expect(T3Attachments.wireMimeType("") == "application/octet-stream")
        #expect(T3Attachments.wireMimeType(String(repeating: "x", count: 101)) == "application/octet-stream")
        #expect(T3Attachments.wireMimeType("Text/Plain") == "text/plain")
    }

    @Test func payloadsMatchTheServerSchemas() {
        let image = T3Attachments.Upload(type: "image", name: "a.png", mimeType: "image/png", sizeBytes: 7, isPastedText: false)
        #expect(image.uploadURLRequest == ["type": "image", "name": "a.png", "mimeType": "image/png", "sizeBytes": 7])
        #expect(
            image.reference(id: "pending-1")
                == ["type": "image", "id": "pending-1", "name": "a.png", "mimeType": "image/png", "sizeBytes": 7]
        )
        let text = T3Attachments.Upload(type: "file", name: "Pasted text.txt", mimeType: "text/plain", sizeBytes: 9, isPastedText: true)
        #expect(text.uploadURLRequest == ["type": "file", "name": "Pasted text.txt", "mimeType": "text/plain", "sizeBytes": 9])
        #expect(
            text.reference(id: "pending-2-txt")
                == [
                    "type": "file", "id": "pending-2-txt", "name": "Pasted text.txt", "mimeType": "text/plain",
                    "sizeBytes": 9, "source": ["_tag": "pasted-text"],
                ]
        )
    }
}

@Suite struct AttachmentCommandTests {
    private let references: [JSONValue] = [
        ["type": "image", "id": "pending-1", "name": "a.png", "mimeType": "image/png", "sizeBytes": 7]
    ]

    @Test func launchCarriesTheAttachmentsAndTheStagedText() {
        let request = LaunchRequest(
            projectID: ProjectID("p1"),
            prompt: "What does this show?",
            attachments: [screenshot],
            providerID: "codex",
            model: "gpt-5.6-luna"
        )
        let payload = T3Commands.launchThread(
            request, text: "What does this show?\n\n<block>", attachments: references, threadID: "thread-1", messageID: "m1"
        )
        // The server claims uploads for a thread the client names.
        #expect(payload.string("threadId") == "thread-1")
        let message = payload.object("initialMessage")
        #expect(message == ["messageId": "m1", "text": "What does this show?\n\n<block>", "attachments": .array(references)])
        // The title comes from the prompt, never from the staged text.
        #expect(payload.string("title") == "What does this show?")
    }

    @Test func launchWithoutAPromptTakesItsTitleFromTheFirstAttachment() {
        let request = LaunchRequest(
            projectID: ProjectID("p1"),
            prompt: "",
            attachments: [screenshot, notes],
            providerID: "codex",
            model: "gpt-5.6-luna"
        )
        let payload = T3Commands.launchThread(request, attachments: references)
        #expect(payload["threadId"] == nil)
        #expect(payload.string("title") == "screenshot.png")
        #expect(payload.bool("generateTitle") == true)
        #expect(payload.object("initialMessage")?.string("text") == "")
        #expect(payload.object("initialMessage")?.array("attachments") == references)
    }

    @Test func dispatchCarriesTheAttachments() {
        let command = T3Commands.dispatchMessage(
            threadID: "t1", text: "", attachments: references, delivery: .automatic, commandID: "c", messageID: "m"
        )
        #expect(
            command == [
                "type": "message.dispatch", "commandId": "c", "createdBy": "user", "creationSource": "web",
                "threadId": "t1", "messageId": "m", "text": "", "attachments": .array(references),
                "deliveryIntent": "auto", "dispatchMode": ["type": "start_immediately"],
            ]
        )
    }
}

@Suite struct AttachmentMappingTests {
    private let threadSegment = "thread-project-1250418c-a713-4f3e-8420-5a6536dcd0d2-1433e791-ee72-4c07-8165-f9ca40715f30"
    private var imageID: String { "\(threadSegment)-0b0e3d5e-9f0a-4c58-8a52-3f6f1f0f6a11" }
    private var textID: String { "\(threadSegment)-7c1f2a44-1b6d-4e0f-9a3b-5d2c8e9f0a12-txt" }

    private func userMessage(text: String, attachments: [JSONValue]) -> JSONValue {
        [
            "id": "item-1", "threadId": "t1", "runId": "run-1", "ordinal": 1, "status": "completed",
            "type": "user_message", "messageId": "m1", "text": .string(text), "attachments": .array(attachments),
        ]
    }

    @Test func idsNameTheStoredExtension() {
        #expect(T3Attachments.storedExtension(inID: textID) == "txt")
        #expect(T3Attachments.storedExtension(inID: imageID) == nil)
        #expect(T3Attachments.storedExtension(inID: "pending-0b0e3d5e-9f0a-4c58-8a52-3f6f1f0f6a11-PDF") == "pdf")
        #expect(T3Attachments.storedExtension(inID: "pending-0b0e3d5e-9f0a-4c58-8a52-3f6f1f0f6a11") == nil)
        #expect(T3Attachments.storedExtension(inID: "short-id") == nil)
    }

    @Test func wireAttachmentsMapWithTheirStoredPaths() throws {
        let store = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        try Data("png".utf8).write(to: store.appendingPathComponent("\(imageID).png"))
        try Data("text".utf8).write(to: store.appendingPathComponent("\(textID).txt"))

        let image = T3Attachments.attachment(
            ["type": "image", "id": .string(imageID), "name": "screenshot.png", "mimeType": "image/png", "sizeBytes": 2_048],
            directory: store
        )
        #expect(
            image == Attachment(
                id: imageID, kind: .image, name: "screenshot.png", mimeType: "image/png", byteCount: 2_048,
                path: store.appendingPathComponent("\(imageID).png").path
            )
        )
        let text = T3Attachments.attachment(
            [
                "type": "file", "id": .string(textID), "name": "Pasted text.txt", "mimeType": "text/plain",
                "sizeBytes": 9_000, "source": ["_tag": "pasted-text"],
            ],
            directory: store
        )
        #expect(
            text == Attachment(
                id: textID, kind: .text, name: "Pasted text", mimeType: "text/plain", byteCount: 9_000,
                path: store.appendingPathComponent("\(textID).txt").path
            )
        )
    }

    @Test func kindsFollowTheWireTypeAndSource() {
        func kind(_ wire: JSONValue) -> Attachment.Kind? { T3Attachments.attachment(wire, directory: nil)?.kind }
        #expect(kind(["type": "image", "id": "x", "name": "a.png", "mimeType": "image/png"]) == .image)
        #expect(kind(["type": "file", "id": "x", "name": "a.heic", "mimeType": "image/heic"]) == .image)
        #expect(kind(["type": "file", "id": "x", "name": "a.pdf", "mimeType": "application/pdf"]) == .file)
        #expect(kind(["type": "file", "id": "x", "name": "p.txt", "mimeType": "text/plain", "source": ["_tag": "pasted-text"]]) == .text)
        // A snapshot source belongs to an image and doesn't make it text.
        #expect(kind(["type": "image", "id": "x", "name": "a.png", "mimeType": "image/png", "source": ["kind": "snap-shot"]]) == .image)
        // An unknown type still shows up, as a file.
        #expect(kind(["type": "audio", "id": "x", "name": "a.m4a", "mimeType": "audio/mp4", "sizeBytes": 3]) == .file)
    }

    @Test func missingContentAndBadEntitiesAreTolerated() throws {
        let store = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        let wire: JSONValue = ["type": "image", "id": .string(imageID), "name": "gone.png", "mimeType": "image/png", "sizeBytes": 5]
        #expect(T3Attachments.attachment(wire, directory: store)?.path == nil)
        #expect(T3Attachments.attachment(wire, directory: nil)?.path == nil)
        #expect(T3Attachments.attachment(["type": "image", "name": "no-id.png"], directory: store) == nil)
        // Only the ID is required.
        #expect(
            T3Attachments.attachment(["id": "x"], directory: nil)
                == Attachment(id: "x", kind: .file, name: "Attachment", mimeType: "application/octet-stream", byteCount: 0, path: nil)
        )
        // An ID never reaches outside the store.
        try Data("secret".utf8).write(to: store.appendingPathComponent("outside.png"))
        let inner = store.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(T3Attachments.storedFile(id: "../outside", mimeType: "image/png", in: inner) == nil)
        #expect(T3Attachments.storedFile(id: "outside", mimeType: "image/png", in: store) != nil)
    }

    @Test func userMessageCarriesItsAttachments() throws {
        let store = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        try Data("png".utf8).write(to: store.appendingPathComponent("\(imageID).png"))
        let item = userMessage(
            text: "",
            attachments: [["type": "image", "id": .string(imageID), "name": "screenshot.png", "mimeType": "image/png", "sizeBytes": 3]]
        )
        let mapped = T3Mapper.timelineItem(item, context: T3Mapper.ItemContext(attachmentsDirectory: store))
        #expect(
            mapped?.content == .userMessage(
                text: "",
                attachments: [
                    Attachment(
                        id: imageID, kind: .image, name: "screenshot.png", mimeType: "image/png", byteCount: 3,
                        path: store.appendingPathComponent("\(imageID).png").path
                    )
                ]
            )
        )
        // A message without the field, from an older server, maps without attachments.
        let bare: JSONValue = ["id": "item-2", "type": "user_message", "text": "hi"]
        #expect(T3Mapper.timelineItem(bare)?.content == .userMessage(text: "hi"))
    }

    @Test func projectionResolvesPathsInItsStore() throws {
        let store = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        try Data("png".utf8).write(to: store.appendingPathComponent("\(imageID).png"))
        let item = userMessage(
            text: "look",
            attachments: [["type": "image", "id": .string(imageID), "name": "a.png", "mimeType": "image/png", "sizeBytes": 3]]
        )
        var projection = ThreadProjection(threadID: "t1", attachmentsDirectory: store)
        projection.load(snapshot: [
            "kind": "snapshot", "snapshotSequence": 1,
            "projection": ["turnItems": [item], "visibleTurnItems": [["visibility": "local", "sourceItemId": "item-1", "item": item]]],
        ])
        guard case .userMessage(let text, let attachments)? = projection.timeline.first?.content else {
            Issue.record("no user message in the timeline")
            return
        }
        #expect(text == "look")
        #expect(attachments.first?.path == store.appendingPathComponent("\(imageID).png").path)
    }
}

@Suite struct AttachmentPathBlockTests {
    private let empty = Attachment(
        id: "e1", kind: .file, name: "empty \"draft\".txt", mimeType: "text/plain", byteCount: 0, path: "/tmp/stage dir/e1.txt"
    )
    private let folder = Attachment(
        id: "f1", kind: .file, name: "Sources", mimeType: "inode/directory", byteCount: 0, path: "/tmp/repo/Sources"
    )

    @Test func blockRoundTrips() {
        let sent = T3Attachments.appendingPathBlock([empty, folder], to: "Compare these.")
        #expect(sent.hasPrefix("Compare these.\n\n<ostra-attachments>\n"))
        #expect(sent.hasSuffix("\n</ostra-attachments>"))
        // The agent reads the paths as they are.
        #expect(sent.contains(#""path":"/tmp/stage dir/e1.txt""#))
        #expect(sent.contains(#""path":"/tmp/repo/Sources""#))
        let received = T3Attachments.splittingPathBlock(sent)
        #expect(received.text == "Compare these.")
        #expect(received.attachments == [empty, folder])
    }

    @Test func blockStandsAloneWhenTheMessageHasNoText() {
        let sent = T3Attachments.appendingPathBlock([empty], to: "")
        #expect(sent.hasPrefix("<ostra-attachments>\n"))
        let received = T3Attachments.splittingPathBlock(sent)
        #expect(received.text == "")
        #expect(received.attachments == [empty])
    }

    @Test func textWithoutABlockIsUntouched() {
        #expect(T3Attachments.appendingPathBlock([], to: "plain") == "plain")
        var pathless = empty
        pathless.path = nil
        #expect(T3Attachments.appendingPathBlock([pathless], to: "plain") == "plain")
        for text in [
            "plain", "  spaced \n", "", "mentions <ostra-attachments> inline",
            "ends with the tag </ostra-attachments>",
            "inline <ostra-attachments>\n{\"path\":\"/x\"}\n</ostra-attachments>",
            "<ostra-attachments>\nno entries\n</ostra-attachments>",
        ] {
            let received = T3Attachments.splittingPathBlock(text)
            #expect(received.text == text)
            #expect(received.attachments.isEmpty)
        }
    }

    @Test func lenientEntriesStillMap() {
        let text = "hi\n\n<ostra-attachments>\nnote\n{\"path\":\"/tmp/a/report.pdf\",\"extra\":1}\nnot json {\n</ostra-attachments>\n"
        let received = T3Attachments.splittingPathBlock(text)
        #expect(received.text == "hi")
        #expect(
            received.attachments == [
                Attachment(
                    id: "/tmp/a/report.pdf", kind: .file, name: "report.pdf", mimeType: "application/octet-stream",
                    byteCount: 0, path: "/tmp/a/report.pdf"
                )
            ]
        )
    }

    @Test func userMessageShowsCleanTextAndBothKindsOfAttachment() {
        let item: JSONValue = [
            "id": "item-1", "type": "user_message", "messageId": "m1",
            "text": .string(T3Attachments.appendingPathBlock([empty], to: "Check both.")),
            "attachments": [["type": "file", "id": "x-1", "name": "notes.md", "mimeType": "text/markdown", "sizeBytes": 12]],
        ]
        let stored = Attachment(id: "x-1", kind: .file, name: "notes.md", mimeType: "text/markdown", byteCount: 12, path: nil)
        #expect(T3Mapper.timelineItem(item)?.content == .userMessage(text: "Check both.", attachments: [stored, empty]))
        // A deduplicated body gets the same treatment.
        let omitted: JSONValue = ["id": "item-2", "type": "user_message", "messageId": "m2", "text": "", "textOmitted": true]
        let context = T3Mapper.ItemContext(messageText: { _ in T3Attachments.appendingPathBlock([self.empty], to: "") })
        #expect(T3Mapper.timelineItem(omitted, context: context)?.content == .userMessage(text: "", attachments: [empty]))
    }
}
