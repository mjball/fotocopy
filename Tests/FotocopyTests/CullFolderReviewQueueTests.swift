import Foundation
import Testing
@testable import Fotocopy

@Suite
@MainActor
struct CullFolderReviewQueueTests {
    @Test func keepAndUndoUpdateTheCachedFolderQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fotocopy-CullFolderReviewQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let day = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("09", isDirectory: true)
            .appendingPathComponent("13", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rawURL = day.appendingPathComponent("IMG_0001.CR3")
        try Data([0]).write(to: rawURL)

        let frame = CullPhoto(
            url: rawURL,
            filename: rawURL.lastPathComponent,
            captureDate: nil,
            dateSource: nil,
            sequenceNumber: nil
        )
        let model = CullViewModel()
        model.folderURL = day
        model.scanResult = CullFolderScan(
            folder: day,
            cr3Count: 1,
            unreadableMetadataCount: 0,
            bursts: [],
            singleFrames: [frame],
            duration: 0
        )
        model.destination = .review(.singleFrames)
        model.selectedFrameURL = rawURL

        model.refreshCullFolderQueue()
        try await waitForQueueRefresh(in: model)
        #expect(model.cullFoldersNeedingReview.first?.unreviewedCount == 1)

        model.keepSelection()
        try await waitForMove(in: model)
        #expect(model.cullFoldersNeedingReview.isEmpty)
        #expect(model.reviewedCullFolders.first?.keptCount == 1)

        model.undoLastMove()
        try await waitForMove(in: model)
        #expect(model.cullFoldersNeedingReview.first?.unreviewedCount == 1)
        #expect(model.reviewedCullFolders.isEmpty)
    }

    private func waitForQueueRefresh(in model: CullViewModel) async throws {
        for _ in 0..<100 {
            if !model.isRefreshingCullFolderQueue, model.cullFolderReviewSnapshot != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CullFolderReviewQueueTests", code: 1)
    }

    private func waitForMove(in model: CullViewModel) async throws {
        for _ in 0..<100 {
            if !model.isMoving { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CullFolderReviewQueueTests", code: 2)
    }
}
