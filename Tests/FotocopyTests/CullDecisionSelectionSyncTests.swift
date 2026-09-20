import Foundation
import Testing
@testable import Fotocopy

@Suite
@MainActor
struct CullDecisionSelectionSyncTests {
    @Test func keepingASingleFrameAdvancesTheOnlyVisibleSelection() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.keepSelection()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.secondURL)
        #expect(fixture.model.previewSelection(in: fixture.frames) == .single(fixture.secondURL))
        #expect(fixture.model.selectedQuickExportURLs == [fixture.secondURL])
    }

    @Test func rejectingASingleFrameAdvancesTheOnlyVisibleSelection() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.rejectSelection()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.secondURL)
        #expect(fixture.model.previewSelection(in: fixture.frames) == .single(fixture.secondURL))
        #expect(fixture.model.selectedQuickExportURLs == [fixture.secondURL])
    }

    @Test func multipleSelectionsUseThePreviewGridUntilOneImageIsChosen() throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.selectSingleFrame(fixture.firstURL)
        fixture.model.selectSingleFrame(fixture.secondURL, extendingQuickExportSelection: true)

        #expect(fixture.model.isQuickExportSelected(fixture.firstURL))
        #expect(fixture.model.isQuickExportSelected(fixture.secondURL))
        #expect(fixture.model.previewSelection(in: fixture.frames) == .grid([fixture.firstURL, fixture.secondURL]))

        fixture.model.selectSingleFrame(fixture.firstURL)

        #expect(fixture.model.previewSelection(in: fixture.frames) == .single(fixture.firstURL))
    }

    @Test func ratingFromThePreviewGridAdvancesToOneNewlySelectedImage() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.selectSingleFrame(fixture.firstURL)
        fixture.model.selectSingleFrame(fixture.secondURL, extendingQuickExportSelection: true)
        #expect(fixture.model.previewSelection(in: fixture.frames) == .grid([fixture.firstURL, fixture.secondURL]))

        fixture.model.keepSelection()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.thirdURL)
        #expect(fixture.model.previewSelection(in: fixture.frames) == .single(fixture.thirdURL))
        #expect(fixture.model.selectedQuickExportURLs == [fixture.thirdURL])
        #expect(FileManager.default.fileExists(atPath: fixture.folderURL.appendingPathComponent("Keeps/IMG_0001.CR3").path))
        #expect(FileManager.default.fileExists(atPath: fixture.folderURL.appendingPathComponent("Keeps/IMG_0002.CR3").path))
        #expect(FileManager.default.fileExists(atPath: fixture.thirdURL.path))
    }

    @Test func rejectingThePreviewGridMovesOnlyTheBlueSelectedImages() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.selectSingleFrame(fixture.firstURL)
        fixture.model.selectSingleFrame(fixture.secondURL, extendingQuickExportSelection: true)

        fixture.model.rejectSelection()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.thirdURL)
        #expect(fixture.model.previewSelection(in: fixture.frames) == .single(fixture.thirdURL))
        #expect(FileManager.default.fileExists(atPath: fixture.folderURL.appendingPathComponent("Rejects/IMG_0001.CR3").path))
        #expect(FileManager.default.fileExists(atPath: fixture.folderURL.appendingPathComponent("Rejects/IMG_0002.CR3").path))
        #expect(FileManager.default.fileExists(atPath: fixture.thirdURL.path))
    }

    @Test func completingTheFinalBurstOneFrameAtATimeContinuesWithSingles() async throws {
        let fixture = try makeBurstAndSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.keepSelection()

        try await waitForDecisionAdvance(
            in: fixture.model,
            expectedFrameURL: fixture.bursts[0].frames[1].url
        )
        #expect(!fixture.model.isReviewingSingles)

        fixture.model.rejectSelection()

        try await waitForReviewSelection(
            in: fixture.model,
            expectedGroupID: .singleFrames,
            expectedFrameURL: fixture.singleFrames[0].url
        )
        #expect(fixture.model.previewSelection(in: fixture.singleFrames) == .single(fixture.singleFrames[0].url))
        #expect(fixture.model.selectedQuickExportURLs == [fixture.singleFrames[0].url])
    }

    @Test func ratingEverySelectedFrameInTheFinalBurstContinuesWithSingles() async throws {
        let fixture = try makeBurstAndSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.selectFrame(fixture.bursts[0].frames[0].url)
        fixture.model.selectFrame(
            fixture.bursts[0].frames[1].url,
            extendingQuickExportSelection: true
        )
        fixture.model.keepSelection()

        try await waitForReviewSelection(
            in: fixture.model,
            expectedGroupID: .singleFrames,
            expectedFrameURL: fixture.singleFrames[0].url
        )
        #expect(fixture.model.previewSelection(in: fixture.singleFrames) == .single(fixture.singleFrames[0].url))
    }

    @Test func terminalBurstHandoffSkipsDecidedSinglesAndUsesAReviewableFilter() async throws {
        let fixture = try makeBurstAndSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.selectReviewGroup(withID: .singleFrames)
        fixture.model.rejectSelection()
        try await waitForDecisionAdvance(
            in: fixture.model,
            expectedFrameURL: fixture.singleFrames[1].url
        )

        fixture.model.singleFrameFilter = .kept
        let currentBurst = try #require(fixture.model.scanResult?.bursts[0])
        fixture.model.selectReviewGroup(withID: .burst(currentBurst.id))
        fixture.model.markAllRejecting(in: currentBurst)

        try await waitForReviewSelection(
            in: fixture.model,
            expectedGroupID: .singleFrames,
            expectedFrameURL: fixture.singleFrames[1].url
        )
        #expect(fixture.model.singleFrameFilter == .undecided)
    }

    @Test func batchDecisionStillAdvancesToTheNextBurstBeforeSingles() async throws {
        let fixture = try makeBurstAndSingleFrameModel(burstCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.markAllRejecting(in: fixture.bursts[0])

        try await waitForReviewSelection(
            in: fixture.model,
            expectedGroupID: .burst(fixture.bursts[1].id),
            expectedFrameURL: fixture.bursts[1].frames[0].url
        )
        #expect(!fixture.model.isReviewingSingles)
    }

    @Test func completingTheFinalBurstStaysThereWhenNoSinglesNeedReview() async throws {
        let fixture = try makeBurstAndSingleFrameModel(singleFrameCount: 0)
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.markAllRejecting(in: fixture.bursts[0])

        try await waitForMove(in: fixture.model)
        #expect(!fixture.model.isReviewingSingles)
        #expect(fixture.model.selectedBurst?.isReviewed == true)
    }

    @Test func failedFinalBurstDecisionDoesNotEnterSingleFrameReview() async throws {
        let fixture = try makeBurstAndSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }
        try FileManager.default.removeItem(at: fixture.bursts[0].frames[0].url)

        fixture.model.markAllRejecting(in: fixture.bursts[0])

        try await waitForMoveFailure(in: fixture.model)
        #expect(fixture.model.selectedReviewGroupID == .burst(fixture.bursts[0].id))
        #expect(!fixture.model.isReviewingSingles)
    }

    private func makeSingleFrameModel() throws -> (model: CullViewModel, folderURL: URL, firstURL: URL, secondURL: URL, thirdURL: URL, frames: [CullPhoto]) {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fotocopy-CullDecisionSelectionSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let firstURL = folderURL.appendingPathComponent("IMG_0001.CR3")
        let secondURL = folderURL.appendingPathComponent("IMG_0002.CR3")
        let thirdURL = folderURL.appendingPathComponent("IMG_0003.CR3")
        FileManager.default.createFile(atPath: firstURL.path, contents: Data())
        FileManager.default.createFile(atPath: secondURL.path, contents: Data())
        FileManager.default.createFile(atPath: thirdURL.path, contents: Data())

        let frames = [firstURL, secondURL, thirdURL].map { url in
            CullPhoto(
                url: url,
                filename: url.lastPathComponent,
                captureDate: nil,
                dateSource: nil,
                sequenceNumber: nil
            )
        }
        let model = CullViewModel()
        model.folderURL = folderURL
        model.scanResult = CullFolderScan(
            folder: folderURL,
            cr3Count: frames.count,
            unreadableMetadataCount: 0,
            bursts: [],
            singleFrames: frames,
            duration: 0
        )
        model.destination = .review(.singleFrames)
        model.selectedFrameURL = firstURL
        return (model, folderURL, firstURL, secondURL, thirdURL, frames)
    }

    private func makeBurstAndSingleFrameModel(
        burstCount: Int = 1,
        singleFrameCount: Int = 2
    ) throws -> (
        model: CullViewModel,
        folderURL: URL,
        bursts: [PhotoBurst],
        singleFrames: [CullPhoto]
    ) {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fotocopy-CullBurstToSingles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var nextSequenceNumber = 1
        func makeFrame() -> CullPhoto {
            let sequenceNumber = nextSequenceNumber
            nextSequenceNumber += 1
            let filename = String(format: "IMG_%04d.CR3", sequenceNumber)
            let url = folderURL.appendingPathComponent(filename)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return CullPhoto(
                url: url,
                filename: filename,
                captureDate: nil,
                dateSource: nil,
                sequenceNumber: sequenceNumber
            )
        }

        let bursts = (0..<burstCount).map { _ in
            PhotoBurst(frames: [makeFrame(), makeFrame()])
        }
        let singleFrames = (0..<singleFrameCount).map { _ in makeFrame() }
        let model = CullViewModel()
        model.folderURL = folderURL
        model.scanResult = CullFolderScan(
            folder: folderURL,
            cr3Count: (burstCount * 2) + singleFrameCount,
            unreadableMetadataCount: 0,
            bursts: bursts,
            singleFrames: singleFrames,
            duration: 0
        )
        if let firstBurst = bursts.first {
            model.destination = .review(.burst(firstBurst.id))
            model.selectedFrameURL = firstBurst.frames[0].url
        }
        return (model, folderURL, bursts, singleFrames)
    }

    private func waitForDecisionAdvance(
        in model: CullViewModel,
        expectedFrameURL: URL
    ) async throws {
        for _ in 0..<100 {
            if !model.isMoving, model.selectedFrameURL == expectedFrameURL {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CullDecisionSelectionSyncTests", code: 1)
    }

    private func waitForReviewSelection(
        in model: CullViewModel,
        expectedGroupID: CullReviewGroupID,
        expectedFrameURL: URL
    ) async throws {
        for _ in 0..<100 {
            if !model.isMoving,
               model.selectedReviewGroupID == expectedGroupID,
               model.selectedFrameURL == expectedFrameURL {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CullDecisionSelectionSyncTests", code: 2)
    }

    private func waitForMove(in model: CullViewModel) async throws {
        for _ in 0..<100 {
            if !model.isMoving { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CullDecisionSelectionSyncTests", code: 3)
    }

    private func waitForMoveFailure(in model: CullViewModel) async throws {
        for _ in 0..<100 {
            if !model.isMoving, model.showMoveError { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CullDecisionSelectionSyncTests", code: 4)
    }
}
