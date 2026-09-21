import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullFolderReviewMetricsTests {
    @Test func burstHeavyFolderHasMorePayoffThanEquivalentSingles() {
        let burstFrames = (1...12).map { photo(number: $0) }
        let burstScan = CullFolderScan(
            folder: URL(fileURLWithPath: "/Photos/2026/09/01"),
            cr3Count: 12,
            unreadableMetadataCount: 0,
            bursts: [PhotoBurst(frames: burstFrames)],
            singleFrames: [],
            duration: 0
        )
        let singlesScan = CullFolderScan(
            folder: URL(fileURLWithPath: "/Photos/2026/09/02"),
            cr3Count: 12,
            unreadableMetadataCount: 0,
            bursts: [],
            singleFrames: burstFrames,
            duration: 0
        )

        let burstMetrics = CullFolderReviewMetrics(scan: burstScan, inventorySignature: "burst")
        let singlesMetrics = CullFolderReviewMetrics(scan: singlesScan, inventorySignature: "singles")

        #expect(burstMetrics.reviewGroupCount == 1)
        #expect(singlesMetrics.reviewGroupCount == 12)
        #expect(burstMetrics.estimatedEffort == 4)
        #expect(singlesMetrics.estimatedEffort == 12)
        #expect(burstMetrics.payoffPerEffort > singlesMetrics.payoffPerEffort)
    }

    @Test func completedBurstsDoNotAddRemainingEffort() {
        let complete = PhotoBurst(frames: [
            photo(number: 1, disposition: .select),
            photo(number: 2, disposition: .reject)
        ])
        let unfinished = PhotoBurst(frames: [
            photo(number: 3, disposition: .select),
            photo(number: 4),
            photo(number: 5)
        ])
        let scan = CullFolderScan(
            folder: URL(fileURLWithPath: "/Photos/2026/09/03"),
            cr3Count: 6,
            unreadableMetadataCount: 0,
            bursts: [complete, unfinished],
            singleFrames: [photo(number: 6)],
            duration: 0
        )

        let metrics = CullFolderReviewMetrics(scan: scan, inventorySignature: "mixed")

        #expect(metrics.unfinishedBurstCount == 1)
        #expect(metrics.unfinishedBurstFrameCount == 3)
        #expect(metrics.unreviewedBurstFrameCount == 2)
        #expect(metrics.unreviewedSingleFrameCount == 1)
        #expect(metrics.reviewGroupCount == 2)
        #expect(metrics.estimatedEffort == 2.75)
    }

    private func photo(
        number: Int,
        disposition: CullDisposition? = nil
    ) -> CullPhoto {
        let filename = String(format: "IMG_%04d.CR3", number)
        return CullPhoto(
            url: URL(fileURLWithPath: "/Photos/2026/09/01/\(filename)"),
            filename: filename,
            captureDate: nil,
            dateSource: nil,
            sequenceNumber: number,
            disposition: disposition
        )
    }
}
