import Foundation
import OstraCore

/// The RPC method names the bridge calls.
enum T3Method {
    static let subscribeServerConfig = "subscribeServerConfig"
    static let subscribeShell = "orchestration.subscribeShell"
    static let subscribeThread = "orchestration.subscribeThread"
    static let archivedShellSnapshot = "orchestration.getArchivedShellSnapshot"
    static let threadProjection = "orchestration.getThreadProjection"
    static let threadTitles = "orchestration.getThreadTitles"
    static let dispatchCommand = "orchestration.dispatchCommand"
    static let launchThread = "orchestration.launchThread"
    static let fullThreadDiff = "orchestration.getFullThreadDiff"
    static let turnItem = "orchestration.getTurnItem"
    static let mutateProject = "projects.mutate"
    static let createUploadURL = "attachments.createUploadUrl"
    static let deleteAttachment = "attachments.delete"
}

/// Builds the payloads for the commands Ostra sends.
///
/// The shapes follow T3 Code's own web client
/// (`packages/client-runtime/src/operations/commands.ts`).
enum T3Commands {
    static func newID() -> String { UUID().uuidString.lowercased() }

    // MARK: - Projects

    static func createProject(projectID: String, title: String, path: String, commandID: String = newID()) -> JSONValue {
        [
            "type": "project.create",
            "commandId": .string(commandID),
            "projectId": .string(projectID),
            "title": .string(title),
            "workspaceRoot": .string(path),
        ]
    }

    static func deleteProject(projectID: String, force: Bool, commandID: String = newID()) -> JSONValue {
        var command: JSONValue = [
            "type": "project.delete",
            "commandId": .string(commandID),
            "projectId": .string(projectID),
        ]
        if force { command = command.setting("force", true) }
        return command
    }

    // MARK: - Threads

    /// The title for a thread that starts from `prompt`: its first line, cut to a readable length.
    ///
    /// - Parameter fallback: The title for an empty prompt, such as the name of the first attachment.
    static func derivedTitle(from prompt: String, fallback: String? = nil) -> String {
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !firstLine.isEmpty else { return "New agent" }
        guard firstLine.count > 60 else { return firstLine }
        let cut = firstLine.prefix(60)
        // Keep the cut when it lands on a word boundary. Otherwise back up to
        // the previous word, unless that drops more than half the title.
        let next = firstLine[firstLine.index(firstLine.startIndex, offsetBy: 60)]
        if next != " ", let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 30 {
            return String(cut[..<space]) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Starts a thread with its first message.
    ///
    /// - Parameters:
    ///   - request: What to launch.
    ///   - text: The message text to send in place of the prompt, for a prompt
    ///     that carries a path block.
    ///   - attachments: The stored attachments, as `T3Attachments.Upload.reference(id:)` builds them.
    ///   - threadID: The ID for the new thread. The server needs one from the
    ///     client to take ownership of uploaded attachments; without
    ///     attachments, leave it nil and the server allocates the ID.
    static func launchThread(
        _ request: LaunchRequest,
        text: String? = nil,
        attachments: [JSONValue] = [],
        threadID: String? = nil,
        commandID: String = newID(),
        messageID: String = newID()
    ) -> JSONValue {
        let explicitTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = !(explicitTitle ?? "").isEmpty
        let workspace: JSONValue =
            switch request.workspace {
            case .projectRoot: ["type": "root"]
            case .newWorktree(let baseRef): ["type": "worktree", "baseRef": .string(baseRef)]
            }
        var command: JSONValue = [
            "commandId": .string(commandID),
            "creationSource": "web",
            "projectId": .string(request.projectID.rawValue),
            "title": .string(
                hasTitle ? explicitTitle! : derivedTitle(from: request.prompt, fallback: request.attachments.first?.name)
            ),
            // The server replaces a derived title with a generated one.
            "generateTitle": .bool(!hasTitle),
            "modelSelection": ["instanceId": .string(request.providerID), "model": .string(request.model)],
            "runtimeMode": .string(request.runtimeMode.rawValue),
            "interactionMode": .string(request.interactionMode.rawValue),
            "workspaceStrategy": workspace,
            "initialMessage": [
                "messageId": .string(messageID),
                "text": .string(text ?? request.prompt),
                "attachments": .array(attachments),
            ],
        ]
        if let threadID { command = command.setting("threadId", .string(threadID)) }
        return command
    }

    /// Sends a message to an existing thread.
    ///
    /// `.automatic` lets the server choose: it starts a run on an idle thread
    /// and steers the active run on a busy one. `.queue` runs the message after
    /// the active run finishes. `attachments` holds the stored attachments, as
    /// `T3Attachments.Upload.reference(id:)` builds them.
    static func dispatchMessage(
        threadID: String,
        text: String,
        attachments: [JSONValue] = [],
        delivery: MessageDelivery,
        commandID: String = newID(),
        messageID: String = newID()
    ) -> JSONValue {
        var command: JSONValue = [
            "type": "message.dispatch",
            "commandId": .string(commandID),
            "createdBy": "user",
            "creationSource": "web",
            "threadId": .string(threadID),
            "messageId": .string(messageID),
            "text": .string(text),
            "attachments": .array(attachments),
        ]
        switch delivery {
        case .automatic:
            command = command.setting("deliveryIntent", "auto")
            command = command.setting("dispatchMode", ["type": "start_immediately"])
        case .queue:
            command = command.setting("dispatchMode", ["type": "queue_after_active"])
        }
        return command
    }

    /// Stops the thread's active work, including commands from earlier runs.
    static func stopThread(threadID: String, commandID: String = newID()) -> JSONValue {
        threadCommand("thread.stop", threadID: threadID, commandID: commandID)
    }

    static func respond(
        threadID: String,
        requestID: String,
        decision: ApprovalDecision,
        commandID: String = newID()
    ) -> JSONValue {
        threadCommand("runtime-request.respond", threadID: threadID, commandID: commandID)
            .setting("requestId", .string(requestID))
            .setting("decision", .string(decision.rawValue))
    }

    static func answer(
        threadID: String,
        requestID: String,
        answers: JSONValue,
        commandID: String = newID()
    ) -> JSONValue {
        threadCommand("runtime-request.respond", threadID: threadID, commandID: commandID)
            .setting("requestId", .string(requestID))
            .setting("answers", answers)
    }

    static func archive(threadID: String) -> JSONValue { threadCommand("thread.archive", threadID: threadID) }
    static func unarchive(threadID: String) -> JSONValue { threadCommand("thread.unarchive", threadID: threadID) }
    static func delete(threadID: String) -> JSONValue { threadCommand("thread.delete", threadID: threadID) }

    static func rename(threadID: String, title: String) -> JSONValue {
        threadCommand("thread.metadata.update", threadID: threadID).setting("title", .string(title))
    }

    static func setRuntimeMode(threadID: String, mode: RuntimeMode) -> JSONValue {
        threadCommand("thread.runtime-mode.set", threadID: threadID).setting("runtimeMode", .string(mode.rawValue))
    }

    /// Moves the read watermark and counts the visit as the user opening the thread.
    static func visit(threadID: String, at date: Date = .now) -> JSONValue {
        threadCommand("thread.visit", threadID: threadID)
            .setting("visitedAt", .string(JSONValue.formatDate(date)))
            .setting("opened", true)
    }

    private static func threadCommand(_ type: String, threadID: String, commandID: String = newID()) -> JSONValue {
        ["type": .string(type), "commandId": .string(commandID), "threadId": .string(threadID)]
    }
}
