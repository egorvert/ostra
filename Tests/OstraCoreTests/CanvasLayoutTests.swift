import CoreGraphics
import Testing
@testable import OstraCore

@Suite struct CanvasLayoutTests {
    private let size = CanvasLayout.footprint
    private let gap = CanvasLayout.cardGap

    @Test func aFreeSpotStaysPut() {
        let target = CGPoint(x: 500, y: 500)
        #expect(CanvasLayout.resolveCollisions(target, avoiding: [.zero]) == target)
    }

    @Test func aCardSlidesOutTheShortestWay() {
        // Mostly beside the other card, a little low: it moves sideways and keeps its height.
        let other = CGPoint.zero
        let target = CGPoint(x: size.width - 20, y: 10)
        let resolved = CanvasLayout.resolveCollisions(target, avoiding: [other])
        #expect(resolved.x == size.width + gap)
        #expect(resolved.y == 10)
        #expect(!CanvasLayout.collides(resolved, with: other))

        // Mostly below it: it moves down and keeps its column.
        let below = CanvasLayout.resolveCollisions(CGPoint(x: 30, y: size.height - 8), avoiding: [other])
        #expect(below.x == 30)
        #expect(below.y == size.height + gap)
    }

    @Test func aCardNeverEndsUpOnTopOfAnother() {
        // A tight cluster where single pushes fight each other.
        let others = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: size.width + gap, y: 0),
            CGPoint(x: 0, y: size.height + gap),
            CGPoint(x: size.width + gap, y: size.height + gap),
        ]
        for target in [CGPoint(x: 110, y: 38), CGPoint(x: 5, y: 5), CGPoint(x: 230, y: 70)] {
            let resolved = CanvasLayout.resolveCollisions(target, avoiding: others)
            for other in others {
                #expect(!CanvasLayout.collides(resolved, with: other))
            }
        }
    }

    @Test func gridSlotsLeaveTheGap() {
        let first = CanvasLayout.firstSlot(anchor: .zero)
        let next = CanvasLayout.freeSlot(anchor: .zero, occupied: [first])
        #expect(!CanvasLayout.collides(next, with: first))
    }
}
