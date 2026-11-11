import CoreGraphics
import Foundation

/// The camera over the canvas: the world point at the view's center, and the zoom.
public struct CameraState: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var zoom: Double

    public init(x: Double = 0, y: Double = 0, zoom: Double = 1) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    public var center: CGPoint {
        get { CGPoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    public static let zoomRange: ClosedRange<Double> = 0.3...1.8
}

/// Geometry rules for the canvas, in world points. Agent positions are card centers.
public enum CanvasLayout {
    /// The agent card.
    public static let cardSize = CGSize(width: 208, height: 64)
    /// What must not overlap. Today that's the card itself.
    public static let footprint = CGSize(width: 208, height: 64)
    /// The grid that new agents snap to. It leaves 24 points between cards.
    public static let cell = CGSize(width: 232, height: 88)
    public static let groupInsetTop: CGFloat = 48
    public static let groupInsetSide: CGFloat = 24
    public static let groupInsetBottom: CGFloat = 24
    public static let groupGap: CGFloat = 96
    /// The size of a project's group while it has no agents.
    public static let emptyGroupSize = CGSize(width: 256, height: 136)

    /// The rectangle a card covers.
    public static func footprintRect(at position: CGPoint) -> CGRect {
        CGRect(
            x: position.x - footprint.width / 2,
            y: position.y - cardSize.height / 2,
            width: footprint.width,
            height: footprint.height
        )
    }

    /// The frame of a project's group: its members plus padding.
    public static func groupFrame(members: [CGPoint], anchor: CGPoint) -> CGRect {
        guard let first = members.first else {
            return CGRect(origin: anchor, size: emptyGroupSize)
        }
        let union = members.dropFirst().reduce(footprintRect(at: first)) { $0.union(footprintRect(at: $1)) }
        return CGRect(
            x: union.minX - groupInsetSide,
            y: union.minY - groupInsetTop,
            width: union.width + groupInsetSide * 2,
            height: union.height + groupInsetTop + groupInsetBottom
        )
    }

    /// Where the first card of a group goes, given the group's anchor (its top-left corner).
    public static func firstSlot(anchor: CGPoint) -> CGPoint {
        CGPoint(
            x: anchor.x + groupInsetSide + footprint.width / 2,
            y: anchor.y + groupInsetTop + cardSize.height / 2
        )
    }

    /// A free position for a new agent in a group.
    ///
    /// The search walks grid slots outward from the group's first slot, so
    /// groups grow as near-squares: 1, then 2 by 2, then 3 by 3.
    public static func freeSlot(anchor: CGPoint, occupied: [CGPoint]) -> CGPoint {
        let origin = firstSlot(anchor: anchor)
        let taken = occupied.map { footprintRect(at: $0).insetBy(dx: -12, dy: -12) }
        for ring in 0..<24 {
            for row in 0...ring {
                for column in 0...ring where max(row, column) == ring {
                    let candidate = CGPoint(
                        x: origin.x + CGFloat(column) * cell.width,
                        y: origin.y + CGFloat(row) * cell.height
                    )
                    let rect = footprintRect(at: candidate)
                    if !taken.contains(where: { $0.intersects(rect) }) {
                        return candidate
                    }
                }
            }
        }
        return origin
    }

    /// The anchor for a new project's group: to the right of everything that exists.
    public static func nextProjectAnchor(existing frames: [CGRect]) -> CGPoint {
        guard let first = frames.first else {
            return CGPoint(x: -emptyGroupSize.width / 2, y: -emptyGroupSize.height / 2)
        }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        return CGPoint(x: union.maxX + groupGap, y: union.minY)
    }

    /// The agent to move to from `origin` when the user presses an arrow key.
    ///
    /// Candidates must lie in the half-plane of `direction`. The score favors
    /// agents that are close and well aligned with the direction.
    public static func neighbor<ID>(
        from origin: CGPoint,
        direction: CGVector,
        candidates: [(id: ID, position: CGPoint)]
    ) -> ID? {
        var best: (id: ID, score: CGFloat)?
        for candidate in candidates {
            let dx = candidate.position.x - origin.x
            let dy = candidate.position.y - origin.y
            let along = dx * direction.dx + dy * direction.dy
            guard along > 1 else { continue }
            let across = abs(dx * direction.dy - dy * direction.dx)
            let score = along + across * 2.2
            if best == nil || score < best!.score {
                best = (candidate.id, score)
            }
        }
        return best?.id
    }
}

/// Friendly names for agents.
public enum AgentNames {
    public static let pool: [String] = [
        "Ada", "Bob", "Cleo", "Dev", "Erica", "Fred", "Gia", "Hugo", "Iris", "John",
        "Kai", "Luna", "Milo", "Nora", "Otto", "Pia", "Quinn", "Remy", "Sage", "Theo",
        "Uma", "Vera", "Wes", "Xena", "Yuki", "Zane", "Jane", "Jeff", "Maya", "Noel",
        "Ravi", "Suki", "Tess", "Enzo", "Lena", "Omar", "Rosa", "Finn", "Juno", "Abel",
    ]

    /// A name nobody in `taken` uses. The agent's ID picks the starting point,
    /// so the same agent gets the same name on a fresh install.
    public static func pick(for id: AgentID, taken: Set<String>) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in id.rawValue.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let start = Int(hash % UInt64(pool.count))
        for offset in 0..<pool.count {
            let name = pool[(start + offset) % pool.count]
            if !taken.contains(name) { return name }
        }
        // Every name is in use: number the repeats.
        var suffix = 2
        while true {
            let name = "\(pool[start]) \(suffix)"
            if !taken.contains(name) { return name }
            suffix += 1
        }
    }
}
