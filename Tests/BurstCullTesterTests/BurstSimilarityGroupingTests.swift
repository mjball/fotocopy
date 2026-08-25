import Foundation
import Testing
@testable import BurstCullTester

@Test func strictnessRegroupsCachedPairMetricsWithoutRescanning() {
    let frames = (0..<3).map { index in
        AnalyzedFrame(
            frameIndex: index,
            url: URL(fileURLWithPath: "/tmp/BL5A\(1000 + index).CR3"),
            filename: "BL5A\(1000 + index).CR3",
            sequenceNumber: 1000 + index,
            sharpness: Double(index)
        )
    }
    let stablePair = AdjacentPairMetric(
        fromFrameIndex: 0,
        toFrameIndex: 1,
        sceneCorrelation: 0.99,
        hashDistance: 1,
        localPeak: 0.04,
        changedTileFraction: 0.01,
        largestChangedRegionTiles: 1,
        localMotion: 0.08
    )
    let movingSubjectPair = AdjacentPairMetric(
        fromFrameIndex: 1,
        toFrameIndex: 2,
        sceneCorrelation: 0.99,
        hashDistance: 1,
        localPeak: 0.18,
        changedTileFraction: 0.04,
        largestChangedRegionTiles: 2,
        localMotion: 0.30
    )
    let analysis = FolderAnalysis(
        folder: URL(fileURLWithPath: "/tmp"),
        cr3Count: 3,
        candidateFrameCount: 3,
        analyzedCount: 3,
        unreadableCount: 0,
        frames: frames,
        adjacentPairs: [stablePair, movingSubjectPair],
        timings: ScanTimings(enumeration: 0, previewExtraction: 0, pairAnalysis: 0, total: 0)
    )

    #expect(analysis.grouped(using: BurstSimilarityConfiguration(strictness: 0)).first?.frames.count == 3)
    #expect(analysis.grouped(using: BurstSimilarityConfiguration(strictness: 1)).first?.frames.count == 2)
}
