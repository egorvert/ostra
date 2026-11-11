import Foundation
import OstraCore
import Testing
@testable import T3Bridge

@Suite struct JSONValueTests {
    @Test func parsesEveryKindOfValue() throws {
        let value = try JSONValue.parse(#"{"s":"text","n":3,"f":1.5,"t":true,"z":false,"nil":null,"a":[1,"two"],"o":{"k":"v"}}"#)
        #expect(value.string("s") == "text")
        #expect(value.int("n") == 3)
        #expect(value.double("f") == 1.5)
        #expect(value.bool("t") == true)
        #expect(value.bool("z") == false)
        #expect(value["nil"]?.isNull == true)
        #expect(value.array("a") == [1, "two"])
        #expect(value.object("o")?.string("k") == "v")
    }

    @Test func booleansAndNumbersStayDistinct() throws {
        let value = try JSONValue.parse(#"{"flag":true,"one":1,"zero":0}"#)
        #expect(value["flag"] == .bool(true))
        #expect(value["one"] == .number(1))
        #expect(value.bool("one") == nil)
        #expect(value.int("flag") == nil)
    }

    @Test func lenientAccessorsReturnNilOnMismatch() throws {
        let value = try JSONValue.parse(#"{"n":3,"s":"x","blank":"  "}"#)
        #expect(value.string("n") == nil)
        #expect(value.int("s") == nil)
        #expect(value.string("missing") == nil)
        #expect(value.array("missing").isEmpty)
        #expect(value.object("s") == nil)
        #expect(value.nonEmptyString("blank") == nil)
        #expect(JSONValue.string("x")["key"] == nil)
    }

    @Test func serializationRoundTrips() throws {
        let original: JSONValue = [
            "id": "0", "payload": ["threadId": "t/1", "flag": true, "count": 42, "ratio": 0.5, "none": nil],
            "headers": [],
        ]
        let text = original.serialized(sortedKeys: true)
        #expect(text == #"{"headers":[],"id":"0","payload":{"count":42,"flag":true,"none":null,"ratio":0.5,"threadId":"t/1"}}"#)
        #expect(try JSONValue.parse(text) == original)
    }

    @Test func parsesTimestampsWithAndWithoutFractions() {
        let fractional = JSONValue.parseDate("2026-11-11T10:36:24.231Z")
        let whole = JSONValue.parseDate("2026-11-11T10:36:24Z")
        #expect(fractional != nil)
        #expect(whole != nil)
        #expect(abs((fractional?.timeIntervalSince(whole!) ?? 0) - 0.231) < 0.001)
        #expect(JSONValue.parseDate("yesterday") == nil)
        #expect(JSONValue.parseDate(JSONValue.formatDate(fractional!)) == fractional)
    }

    @Test func malformedInputThrows() {
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{not json") }
    }
}

@Suite struct RPCFrameTests {
    @Test func requestMatchesTheEffectRPCShape() {
        let frame = RPCFrame.request(id: "7", tag: "orchestration.subscribeThread", payload: ["threadId": "t1"])
        #expect(
            frame.serialized(sortedKeys: true)
                == #"{"_tag":"Request","headers":[],"id":"7","payload":{"threadId":"t1"},"tag":"orchestration.subscribeThread"}"#
        )
        #expect(RPCFrame.ack(requestID: "7").serialized(sortedKeys: true) == #"{"_tag":"Ack","requestId":"7"}"#)
        #expect(RPCFrame.interrupt(requestID: "7").serialized(sortedKeys: true) == #"{"_tag":"Interrupt","requestId":"7"}"#)
    }

    @Test func decodesChunksAndExits() throws {
        let chunk = try JSONValue.parse(#"{"_tag":"Chunk","requestId":"1","values":[{"kind":"synchronized"},{"kind":"x"}]}"#)
        #expect(RPCFrame.decode(chunk) == [.chunk(requestID: "1", values: [["kind": "synchronized"], ["kind": "x"]])])

        let success = try JSONValue.parse(#"{"_tag":"Exit","requestId":"5","exit":{"_tag":"Success","value":{"sequence":33}}}"#)
        #expect(RPCFrame.decode(success) == [.success(requestID: "5", value: ["sequence": 33])])

        // A stream ends with a success that carries no value.
        let ended = try JSONValue.parse(#"{"_tag":"Exit","requestId":"2","exit":{"_tag":"Success"}}"#)
        #expect(RPCFrame.decode(ended) == [.success(requestID: "2", value: .null)])
    }

    @Test func decodesTypedFailures() throws {
        let failure = try JSONValue.parse(
            #"{"_tag":"Exit","requestId":"3","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2DispatchCommandError","commandId":"c","commandType":"thread.archive","message":"Thread not found.","detail":"It was deleted."}}]}}"#
        )
        guard case .failure(let id, let error) = try #require(RPCFrame.decode(failure).first) else {
            Issue.record("not a failure")
            return
        }
        #expect(id == "3")
        #expect(error.kind == .failure)
        #expect(error.tag == "OrchestrationV2DispatchCommandError")
        #expect(error.message == "Thread not found. It was deleted.")
    }

    @Test func decodesDefectsAndInterrupts() throws {
        let die = try JSONValue.parse(#"{"_tag":"Exit","requestId":"4","exit":{"_tag":"Failure","cause":[{"_tag":"Die","defect":"boom"}]}}"#)
        guard case .failure(_, let dieError) = try #require(RPCFrame.decode(die).first) else {
            Issue.record("not a failure")
            return
        }
        #expect(dieError.kind == .defect)
        #expect(dieError.message == "boom")

        let interrupted = try JSONValue.parse(#"{"_tag":"Exit","requestId":"4","exit":{"_tag":"Failure","cause":[{"_tag":"Interrupt"}]}}"#)
        guard case .failure(_, let interruptError) = try #require(RPCFrame.decode(interrupted).first) else {
            Issue.record("not a failure")
            return
        }
        #expect(interruptError.tag == "Interrupt")

        let socketDefect = try JSONValue.parse(#"{"_tag":"Defect","defect":{"message":"Server exploded"}}"#)
        #expect(RPCFrame.decode(socketDefect) == [.defect(message: "Server exploded")])
    }

    @Test func toleratesBatchesAndUnknownFrames() throws {
        let batch = try JSONValue.parse(#"[{"_tag":"Pong"},{"_tag":"Chunk","requestId":"1","values":[]},{"_tag":"FutureFrame"},{"oops":1}]"#)
        #expect(RPCFrame.decode(batch) == [.pong, .chunk(requestID: "1", values: []), .unknown, .unknown])
    }
}

@Suite struct T3CommandsTests {
    @Test func launchUsesADerivedTitleAndAsksForAGeneratedOne() {
        let request = LaunchRequest(
            projectID: ProjectID("p1"),
            prompt: "Fix the flaky login test\nand tidy the fixtures",
            providerID: "codex",
            model: "gpt-5.6-luna",
            runtimeMode: .autoAcceptEdits,
            interactionMode: .plan
        )
        let payload = T3Commands.launchThread(request, commandID: "cmd-1")
        #expect(payload.string("commandId") == "cmd-1")
        #expect(payload.string("creationSource") == "web")
        #expect(payload.string("projectId") == "p1")
        #expect(payload.string("title") == "Fix the flaky login test")
        #expect(payload.bool("generateTitle") == true)
        #expect(payload["modelSelection"] == ["instanceId": "codex", "model": "gpt-5.6-luna"])
        #expect(payload.string("runtimeMode") == "auto-accept-edits")
        #expect(payload.string("interactionMode") == "plan")
        #expect(payload["workspaceStrategy"] == ["type": "root"])
        let message = payload.object("initialMessage")
        #expect(message?.string("text") == "Fix the flaky login test\nand tidy the fixtures")
        #expect(message?.array("attachments").isEmpty == true)
        #expect(message?.string("messageId")?.isEmpty == false)
    }

    @Test func launchKeepsAnExplicitTitleAndMapsAWorktree() {
        let request = LaunchRequest(
            projectID: ProjectID("p1"),
            prompt: "Do the thing",
            title: "  Auth refactor ",
            providerID: "claudeAgent",
            model: "claude-opus-5-5",
            workspace: .newWorktree(baseRef: "main")
        )
        let payload = T3Commands.launchThread(request)
        #expect(payload.string("title") == "Auth refactor")
        #expect(payload.bool("generateTitle") == false)
        #expect(payload["workspaceStrategy"] == ["type": "worktree", "baseRef": "main"])
    }

    @Test func derivedTitlesAreShort() {
        #expect(T3Commands.derivedTitle(from: "   \n\n  ") == "New agent")
        #expect(T3Commands.derivedTitle(from: "\n  Short task  \nmore") == "Short task")
        let long = "Refactor the authentication middleware so that tokens rotate automatically every hour"
        let title = T3Commands.derivedTitle(from: long)
        #expect(title == "Refactor the authentication middleware so that tokens rotate…")
        #expect(title.count <= 61)
        let unbroken = String(repeating: "a", count: 90)
        #expect(T3Commands.derivedTitle(from: unbroken) == String(repeating: "a", count: 60) + "…")
    }

    @Test func automaticDeliveryLetsTheServerSteerOrStart() {
        let command = T3Commands.dispatchMessage(threadID: "t1", text: "keep going", delivery: .automatic, commandID: "c", messageID: "m")
        #expect(
            command == [
                "type": "message.dispatch", "commandId": "c", "createdBy": "user", "creationSource": "web",
                "threadId": "t1", "messageId": "m", "text": "keep going", "attachments": [],
                "deliveryIntent": "auto", "dispatchMode": ["type": "start_immediately"],
            ]
        )
    }

    @Test func queuedDeliveryWaitsForTheActiveRun() {
        let command = T3Commands.dispatchMessage(threadID: "t1", text: "after that", delivery: .queue, commandID: "c", messageID: "m")
        #expect(command["dispatchMode"] == ["type": "queue_after_active"])
        #expect(command["deliveryIntent"] == nil)
    }

    @Test func threadCommandsCarryTheirFields() {
        #expect(T3Commands.stopThread(threadID: "t1", commandID: "c") == ["type": "thread.stop", "commandId": "c", "threadId": "t1"])
        #expect(
            T3Commands.respond(threadID: "t1", requestID: "rq", decision: .acceptForSession, commandID: "c")
                == ["type": "runtime-request.respond", "commandId": "c", "threadId": "t1", "requestId": "rq", "decision": "acceptForSession"]
        )
        #expect(
            T3Commands.answer(threadID: "t1", requestID: "rq", answers: ["q1": "Swift"], commandID: "c")
                == ["type": "runtime-request.respond", "commandId": "c", "threadId": "t1", "requestId": "rq", "answers": ["q1": "Swift"]]
        )
        #expect(T3Commands.archive(threadID: "t1").string("type") == "thread.archive")
        #expect(T3Commands.unarchive(threadID: "t1").string("type") == "thread.unarchive")
        #expect(T3Commands.delete(threadID: "t1").string("type") == "thread.delete")
        #expect(T3Commands.rename(threadID: "t1", title: "New").string("title") == "New")
        #expect(T3Commands.setRuntimeMode(threadID: "t1", mode: .fullAccess).string("runtimeMode") == "full-access")

        let visit = T3Commands.visit(threadID: "t1", at: Date(timeIntervalSince1970: 1_794_393_384.231))
        #expect(visit.string("type") == "thread.visit")
        #expect(visit.string("visitedAt") == "2026-11-11T10:36:24.231Z")
        #expect(visit.bool("opened") == true)
    }

    @Test func projectCommands() {
        #expect(
            T3Commands.createProject(projectID: "p1", title: "ostra", path: "/code/ostra", commandID: "c")
                == ["type": "project.create", "commandId": "c", "projectId": "p1", "title": "ostra", "workspaceRoot": "/code/ostra"]
        )
        #expect(T3Commands.deleteProject(projectID: "p1", force: false, commandID: "c")["force"] == nil)
        #expect(T3Commands.deleteProject(projectID: "p1", force: true, commandID: "c").bool("force") == true)
    }

    @Test func idsAreUniqueLowercaseUUIDs() {
        let first = T3Commands.newID()
        #expect(first != T3Commands.newID())
        #expect(first == first.lowercased())
        #expect(UUID(uuidString: first) != nil)
    }
}

@Suite struct RuntimeSupportTests {
    @Test func configurationPinsTheRelease() {
        let configuration = T3Configuration(supportDirectory: URL(fileURLWithPath: "/tmp/ostra-support"), binaryOverride: nil)
        #expect(configuration.version == "0.1.8")
        #expect(configuration.homeDirectory.path == "/tmp/ostra-support/t3-home")
        #expect(configuration.sessionTokenFile.path == "/tmp/ostra-support/session-token")
        #expect(configuration.serverRecordFile.path == "/tmp/ostra-support/server.json")
        #expect(configuration.serverLogFile.path == "/tmp/ostra-support/logs/t3-server.log")
        let installer = RuntimeInstaller(configuration: configuration)
        #expect(installer.versionDirectory.path == "/tmp/ostra-support/runtime/versions/0.1.8")
    }

    @Test func findsTheChecksumForAnArchive() {
        let sums = """
        1111111111111111111111111111111111111111111111111111111111111111  t3-0.1.8-linux-x64.tar.gz
        A95BE61A0260F8DAF62F0E218BD3E60386A6674D32A3FC46E2D3BC159F9B7DAA *t3-0.1.8-darwin-arm64.tar.gz
        not-a-hash  t3-0.1.8-win32-x64.zip
        """
        #expect(
            RuntimeInstaller.checksum(for: "t3-0.1.8-darwin-arm64.tar.gz", in: sums)
                == "a95be61a0260f8daf62f0e218bd3e60386a6674d32a3fc46e2d3bc159f9b7daa"
        )
        #expect(RuntimeInstaller.checksum(for: "t3-0.1.8-win32-x64.zip", in: sums) == nil)
        #expect(RuntimeInstaller.checksum(for: "t3-9.9.9-darwin-arm64.tar.gz", in: sums) == nil)
    }

    @Test func hashesAFileInChunks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ostra-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try RuntimeInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func binaryOverrideMustBeExecutable() async {
        let configuration = T3Configuration(
            supportDirectory: URL(fileURLWithPath: "/tmp/ostra-support"),
            binaryOverride: URL(fileURLWithPath: "/nonexistent/t3")
        )
        await #expect(throws: BackendError.self) {
            _ = try await RuntimeInstaller(configuration: configuration).ensureInstalled { _, _ in }
        }
    }

    @Test func pathEntriesMergeInOrderWithoutDuplicates() {
        #expect(
            ServerSupervisor.mergePathEntries(["/opt/homebrew/bin", "/usr/bin", "", "/opt/homebrew/bin", "/bin"])
                == "/opt/homebrew/bin:/usr/bin:/bin"
        )
    }

    @Test func freePortIsUsable() throws {
        let port = try ServerSupervisor.freePort()
        #expect(port > 1023)
        #expect(port < 65_536)
    }

    @Test func serverRecordRoundTrips() throws {
        let record = ServerRecord(pid: 4242, port: 55_126, version: "0.1.8", environmentID: "env-1")
        #expect(ServerRecord(json: try JSONValue.parse(record.json.serialized())) == record)
        #expect(ServerRecord(json: ["port": 1]) == nil)
    }

    @Test func endpointBuildsTheSocketURL() {
        let url = ServerEndpoint(port: 43_917).webSocketURL(ticket: "a+b/c=")
        #expect(url.scheme == "ws")
        #expect(url.port == 43_917)
        #expect(url.path == "/ws")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "orchestrationProtocol" }?.value == "2")
        #expect(items.first { $0.name == "wsTicket" }?.value == "a+b/c=")
    }

    @Test func onlyT3ProcessesCountAsServers() {
        #expect(!ServerSupervisor.isT3Process(ProcessInfo.processInfo.processIdentifier))
        #expect(!ServerSupervisor.isT3Process(0))
        #expect(!ServerSupervisor.isT3Process(-1))
    }

    @Test func tokenIsTheLastBareLineOfTheCLIOutput() {
        #expect(T3Auth.extractToken(from: "[10:00:00] INFO: Migrations ran successfully\n\neyJ2IjoxfQ.signature\n") == "eyJ2IjoxfQ.signature")
        #expect(T3Auth.extractToken(from: "\n\n") == nil)
    }
}
