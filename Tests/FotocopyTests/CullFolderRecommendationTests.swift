import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullFolderRecommendationTests {
    @Test func budgetsTenSlotsAcrossTheRecommendationReasons() throws {
        let summaries = (1...20).map { index in
            summary(
                day: index,
                unreviewed: index,
                kept: index.isMultiple(of: 3) ? index : 0
            )
        }
        let resumeFolder = try #require(summaries.last { $0.keptCount > 0 })
        let result = CullFolderRecommendationEngine.recommendations(
            from: summaries,
            currentFolderURL: nil,
            lastOpenedAt: [resumeFolder.folderURL.path: 100]
        )

        #expect(result.recommended.count == 10)
        #expect(Set(result.recommended.map(\.folderURL)).count == 10)
        #expect(result.remainingFolderURLs.count == 10)
        #expect(result.recommended.count { $0.reason == .resume } == 1)
        #expect(result.recommended.count { $0.reason == .largeOpportunity } == 3)
        #expect(result.recommended.count { $0.reason == .closeToDone } == 2)
        #expect(result.recommended.count { $0.reason == .aging } == 2)
        #expect(result.recommended.count { $0.reason == .largestBacklog } == 1)
        #expect(result.recommended.count { $0.reason == .newest } == 1)
    }

    @Test func currentFolderReplacesTheLastRecommendationWithoutCreatingAnEleventhRow() throws {
        let summaries = (1...12).map { summary(day: $0, unreviewed: $0) }
        let current = try #require(summaries.first { $0.folderURL.lastPathComponent == "06" })
        let baseline = CullFolderRecommendationEngine.recommendations(
            from: summaries,
            currentFolderURL: nil,
            lastOpenedAt: [:]
        )
        #expect(!baseline.recommended.contains { $0.folderURL == current.folderURL })

        let result = CullFolderRecommendationEngine.recommendations(
            from: summaries,
            currentFolderURL: current.folderURL,
            lastOpenedAt: [:]
        )

        #expect(result.recommended.count == 10)
        #expect(result.recommended.first == CullFolderRecommendation(
            folderURL: current.folderURL,
            reason: .current
        ))
        #expect(!result.remainingFolderURLs.contains(current.folderURL))
    }

    @Test func fewerThanTenFoldersAreAllRecommendedAndReviewedFoldersAreExcluded() {
        let unreviewed = (1...4).map { summary(day: $0, unreviewed: $0) }
        let reviewed = summary(day: 5, unreviewed: 0, kept: 3)

        let result = CullFolderRecommendationEngine.recommendations(
            from: unreviewed + [reviewed],
            currentFolderURL: nil,
            lastOpenedAt: [:]
        )

        #expect(result.recommended.count == 4)
        #expect(result.remainingFolderURLs.isEmpty)
        #expect(!result.recommended.contains { $0.folderURL == reviewed.folderURL })
    }

    @Test func recommendationsAreDeterministicAcrossInputOrder() {
        let summaries = (1...15).map {
            summary(day: $0, unreviewed: ($0 * 7) % 13 + 1, kept: $0 % 4)
        }
        let activity = Dictionary(
            uniqueKeysWithValues: summaries.enumerated().map { ($0.element.folderURL.path, Double($0.offset)) }
        )

        let forward = CullFolderRecommendationEngine.recommendations(
            from: summaries,
            currentFolderURL: nil,
            lastOpenedAt: activity
        )
        let reversed = CullFolderRecommendationEngine.recommendations(
            from: Array(summaries.reversed()),
            currentFolderURL: nil,
            lastOpenedAt: activity
        )

        #expect(forward == reversed)
    }

    @Test func exactMetricsReplaceCountOnlyFallbackSlots() {
        let summaries = (1...20).map { index in
            summary(
                day: index,
                unreviewed: index,
                kept: index.isMultiple(of: 3) ? index : 0
            )
        }
        let metrics = Dictionary(uniqueKeysWithValues: summaries.map { summary in
            (
                summary.folderURL,
                CullFolderReviewMetrics(
                    inventorySignature: summary.inventorySignature,
                    unfinishedBurstCount: 1,
                    unfinishedBurstFrameCount: summary.unreviewedCount,
                    unreviewedBurstFrameCount: summary.unreviewedCount,
                    unreviewedSingleFrameCount: 0,
                    calculatedAt: 1
                )
            )
        })

        let result = CullFolderRecommendationEngine.recommendations(
            from: summaries,
            currentFolderURL: nil,
            lastOpenedAt: [:],
            metricsByFolderURL: metrics
        )

        #expect(result.recommended.count { $0.reason == .highPayoff } == 3)
        #expect(result.recommended.count { $0.reason == .quickWin } == 2)
        #expect(result.recommended.count { $0.reason == .largeOpportunity } == 0)
        #expect(result.recommended.count { $0.reason == .closeToDone } == 0)
    }

    private func summary(
        day: Int,
        unreviewed: Int,
        kept: Int = 0,
        rejected: Int = 0
    ) -> CullFolderReviewSummary {
        CullFolderReviewSummary(
            folderURL: URL(fileURLWithPath: String(format: "/Photos/2026/09/%02d", day)),
            unreviewedCount: unreviewed,
            keptCount: kept,
            rejectedCount: rejected
        )
    }
}
