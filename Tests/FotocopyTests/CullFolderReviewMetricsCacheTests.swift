import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullFolderReviewMetricsCacheTests {
    @Test func persistsValidMetricsAcrossCacheInstances() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metrics = makeMetrics(signature: "inventory-a")

        let writer = CullFolderReviewMetricsCache(cacheURL: fixture.cacheURL)
        await writer.store(
            metrics,
            libraryRootURL: fixture.libraryRoot,
            folderURL: fixture.folderURL
        )

        let reader = CullFolderReviewMetricsCache(cacheURL: fixture.cacheURL)
        let loaded = await reader.validMetrics(
            for: [makeSummary(folderURL: fixture.folderURL, signature: "inventory-a")],
            libraryRootURL: fixture.libraryRoot
        )

        #expect(loaded[fixture.folderURL] == metrics)
    }

    @Test func rejectsMetricsWhenTheInventorySignatureChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = CullFolderReviewMetricsCache(cacheURL: fixture.cacheURL)
        await cache.store(
            makeMetrics(signature: "inventory-a"),
            libraryRootURL: fixture.libraryRoot,
            folderURL: fixture.folderURL
        )

        let loaded = await cache.validMetrics(
            for: [makeSummary(folderURL: fixture.folderURL, signature: "inventory-b")],
            libraryRootURL: fixture.libraryRoot
        )

        #expect(loaded.isEmpty)
    }

    @Test func corruptCacheFallsBackToNoMetrics() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("not-json".utf8).write(to: fixture.cacheURL)

        let cache = CullFolderReviewMetricsCache(cacheURL: fixture.cacheURL)
        let loaded = await cache.validMetrics(
            for: [makeSummary(folderURL: fixture.folderURL, signature: "inventory-a")],
            libraryRootURL: fixture.libraryRoot
        )

        #expect(loaded.isEmpty)
    }

    private func makeFixture() throws -> (
        root: URL,
        cacheURL: URL,
        libraryRoot: URL,
        folderURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fotocopy-MetricsCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let folderURL = libraryRoot.appendingPathComponent("2026/09/01", isDirectory: true)
        return (
            root,
            root.appendingPathComponent("metrics.json"),
            libraryRoot,
            folderURL
        )
    }

    private func makeSummary(
        folderURL: URL,
        signature: String
    ) -> CullFolderReviewSummary {
        CullFolderReviewSummary(
            folderURL: folderURL,
            unreviewedCount: 12,
            keptCount: 0,
            rejectedCount: 0,
            inventorySignature: signature
        )
    }

    private func makeMetrics(signature: String) -> CullFolderReviewMetrics {
        CullFolderReviewMetrics(
            inventorySignature: signature,
            unfinishedBurstCount: 2,
            unfinishedBurstFrameCount: 12,
            unreviewedBurstFrameCount: 10,
            unreviewedSingleFrameCount: 2,
            calculatedAt: 123
        )
    }
}
