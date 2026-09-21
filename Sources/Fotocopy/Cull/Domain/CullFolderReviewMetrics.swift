import Foundation

/// Derived review-shape data used only to rank the sidebar queue. These values
/// never authorize file operations and can always be rebuilt from a folder.
struct CullFolderReviewMetrics: Codable, Sendable, Equatable {
    static let effortPerBurstFrame = 0.25

    let inventorySignature: String
    let unfinishedBurstCount: Int
    let unfinishedBurstFrameCount: Int
    let unreviewedBurstFrameCount: Int
    let unreviewedSingleFrameCount: Int
    let calculatedAt: TimeInterval

    var unreviewedCount: Int {
        unreviewedBurstFrameCount + unreviewedSingleFrameCount
    }

    var reviewGroupCount: Int {
        unfinishedBurstCount + unreviewedSingleFrameCount
    }

    var estimatedEffort: Double {
        Double(unreviewedSingleFrameCount + unfinishedBurstCount)
            + (Double(unfinishedBurstFrameCount) * Self.effortPerBurstFrame)
    }

    var payoffPerEffort: Double {
        guard estimatedEffort > 0 else { return 0 }
        return Double(unreviewedCount) / estimatedEffort
    }

    init(
        scan: CullFolderScan,
        inventorySignature: String,
        calculatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let unfinishedBursts = scan.bursts.filter { burst in
            burst.frames.contains { $0.disposition == nil }
        }
        self.inventorySignature = inventorySignature
        self.unfinishedBurstCount = unfinishedBursts.count
        self.unfinishedBurstFrameCount = unfinishedBursts.reduce(0) { $0 + $1.frames.count }
        self.unreviewedBurstFrameCount = unfinishedBursts.reduce(0) { result, burst in
            result + burst.frames.count { $0.disposition == nil }
        }
        self.unreviewedSingleFrameCount = scan.singleFrames.count { $0.disposition == nil }
        self.calculatedAt = calculatedAt
    }

    init(
        inventorySignature: String,
        unfinishedBurstCount: Int,
        unfinishedBurstFrameCount: Int,
        unreviewedBurstFrameCount: Int,
        unreviewedSingleFrameCount: Int,
        calculatedAt: TimeInterval
    ) {
        self.inventorySignature = inventorySignature
        self.unfinishedBurstCount = unfinishedBurstCount
        self.unfinishedBurstFrameCount = unfinishedBurstFrameCount
        self.unreviewedBurstFrameCount = unreviewedBurstFrameCount
        self.unreviewedSingleFrameCount = unreviewedSingleFrameCount
        self.calculatedAt = calculatedAt
    }
}
