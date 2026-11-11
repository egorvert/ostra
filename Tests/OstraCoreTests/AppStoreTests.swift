import CoreGraphics
import Foundation
import Testing
@testable import OstraCore

@MainActor
@Suite struct AppStoreTests {
    /// Starts a store on the seeded mock and waits for the first snapshot.
    private func loadedStore(pace: Double = 0) async -> AppStore {
        let store = AppStore(backend: MockBackend(seeded: true, pace: pace))
        store.start()
        await waitUntil { store.hasLoaded && store.connection.isReady }
        return store
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test func snapshotPopulatesTheCanvas() async {
        let store = await loadedStore(pace: 1)
        #expect(store.projects.count == 2)
        #expect(store.agents.count == 6)
        #expect(Set(store.agents.map(\.name)).count == 6, "names are unique")
        // No two cards overlap, and no two groups overlap.
        let rects = store.agents.map { CanvasLayout.footprintRect(at: $0.position) }
        for (i, a) in rects.enumerated() {
            for b in rects.dropFirst(i + 1) {
                #expect(!a.intersects(b))
            }
        }
        let groups = store.projects.map { store.groupFrame(for: $0.id) }
        #expect(!groups[0].intersects(groups[1]))
        await store.shutdown()
    }

    @Test func cycleWrapsAndHonorsTheFilter() async {
        let store = await loadedStore(pace: 1)
        let order = store.canvasOrder.map(\.id)
        store.cycle(forward: true)
        #expect(store.selectedAgentID == order[0])
        store.cycle(forward: false)
        #expect(store.selectedAgentID == order[order.count - 1])
        store.cycle(forward: true)
        #expect(store.selectedAgentID == order[0])

        // The seeded agent with a question blocks about a second after launch.
        await waitUntil { store.agents.contains { $0.phase == .awaitingInput } }
        store.select(nil)
        store.cycleFilter = .attention
        let wanting = store.cycleCandidates.map(\.id)
        #expect(!wanting.isEmpty)
        #expect(wanting.allSatisfy { store.agent($0)!.needsAttention })
        #expect(wanting.count < store.agents.count)
        store.cycle(forward: true)
        #expect(store.selectedAgentID == wanting[0])
        await store.shutdown()
    }

    @Test func archiveMovesSelectionAndUndoRestores() async {
        let store = await loadedStore(pace: 1)
        let target = store.canvasOrder[1]
        store.select(target.id)
        store.archive(target.id)
        await waitUntil { store.agent(target.id) == nil }
        #expect(store.selectedAgentID != nil)
        #expect(store.selectedAgentID != target.id)
        #expect(store.archivedAgents.contains { $0.id == target.id })

        await waitUntil { store.toasts.contains { $0.actionLabel == "Undo" } }
        #expect(store.performToastAction())
        await waitUntil { store.agent(target.id) != nil }
        await store.shutdown()
    }

    @Test func spawnCreatesAndSelectsAnAgent() async {
        let store = await loadedStore(pace: 0)
        let before = store.agents.count
        store.spawn(prompt: "Add a health check endpoint")
        await waitUntil { store.agents.count == before + 1 && store.selectedAgentID != nil }
        let agent = store.selectedAgent!
        #expect(agent.title == "Add a health check endpoint")
        #expect(agent.projectID == store.currentProjectID)
        // The scripted run stops at an approval; accept it and the run finishes.
        await waitUntil { agent.phase == .awaitingApproval }
        store.respond(.accept, to: agent.id)
        await waitUntil { agent.phase == .done }
        #expect(agent.changes.files == 2)
        #expect(!agent.conversation.items.isEmpty)
        await store.shutdown()
    }

    @Test func neighborFollowsDirection() {
        let candidates: [(id: String, position: CGPoint)] = [
            ("right", CGPoint(x: 300, y: 10)),
            ("below", CGPoint(x: 0, y: 200)),
            ("far-right", CGPoint(x: 900, y: 0)),
        ]
        #expect(CanvasLayout.neighbor(from: .zero, direction: CGVector(dx: 1, dy: 0), candidates: candidates) == "right")
        #expect(CanvasLayout.neighbor(from: .zero, direction: CGVector(dx: 0, dy: 1), candidates: candidates) == "below")
        #expect(CanvasLayout.neighbor(from: .zero, direction: CGVector(dx: -1, dy: 0), candidates: candidates) == nil)
    }
}

@Suite struct ParserTests {
    @Test func unifiedDiffCountsLinesPerFile() {
        let files = UnifiedDiff.parse(MockBackend.sampleDiff)
        #expect(files.map(\.path) == ["Sources/Auth/Redirect.swift", "Tests/AuthTests/RedirectTests.swift"])
        #expect(files[0].kind == .modified)
        #expect(files[1].kind == .added)
        #expect(files[0].additions == 10)
        #expect(files[0].deletions == 2)
        #expect(files[1].additions == 10)
        let firstAddition = files[0].hunks[0].lines.first { $0.kind == .addition }
        #expect(firstAddition?.newNumber == 8)
    }

    @Test func markdownSplitsBlocks() {
        let blocks = Markdown.blocks(MockBackend.summaryText)
        #expect(blocks.count == 5)
        guard case let .list(items, ordered) = blocks[2] else {
            Issue.record("expected a list, got \(blocks[2])")
            return
        }
        #expect(!ordered)
        #expect(items.count == 3)
        guard case let .code(language, text) = blocks[3] else {
            Issue.record("expected code, got \(blocks[3])")
            return
        }
        #expect(language == "swift")
        #expect(text.hasPrefix("guard let host"))
    }

    @Test func markdownToleratesAnUnclosedFence() {
        let blocks = Markdown.blocks("Here:\n```swift\nlet x = 1")
        #expect(blocks == [.paragraph("Here:"), .code(language: "swift", text: "let x = 1")])
    }

    @Test func liveLineUnwrapsShellCommands() {
        #expect(LiveLine.shortCommand("/bin/zsh -lc 'ls -la'") == "ls -la")
        #expect(LiveLine.shortCommand("git status") == "git status")
    }
}
