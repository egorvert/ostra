import Foundation
import Testing
@testable import OstraCore

@Suite struct AgentSnapshotTests {
    private func agent(phase: AgentPhase, completedAt: Date? = nil, lastVisitedAt: Date? = nil) -> AgentSnapshot {
        AgentSnapshot(
            id: AgentID("a"),
            projectID: ProjectID("p"),
            title: "Task",
            providerID: "codex",
            model: "m",
            phase: phase,
            completedAt: completedAt,
            lastVisitedAt: lastVisitedAt
        )
    }

    @Test func blockedAgentsNeedAttention() {
        #expect(agent(phase: .awaitingApproval).needsAttention)
        #expect(agent(phase: .awaitingInput).needsAttention)
        #expect(!agent(phase: .working).needsAttention)
    }

    @Test func finishedAgentNeedsAttentionUntilVisited() {
        let finished = Date(timeIntervalSince1970: 100)
        #expect(agent(phase: .done, completedAt: finished).needsAttention)
        #expect(agent(phase: .done, completedAt: finished, lastVisitedAt: Date(timeIntervalSince1970: 50)).needsAttention)
        #expect(!agent(phase: .done, completedAt: finished, lastVisitedAt: Date(timeIntervalSince1970: 150)).needsAttention)
    }
}
