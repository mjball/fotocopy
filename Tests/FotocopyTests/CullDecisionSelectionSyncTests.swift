import Foundation
import Testing
@testable import Fotocopy

@Suite
@MainActor
struct CullDecisionSelectionSyncTests {
    @Test func keepingASingleFrameAdvancesTheOnlyVisibleSelection() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.keepSelectedFrame()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.secondURL)
        #expect(fixture.model.previewSelection(in: fixture.frames) == .single(fixture.secondURL))
        #expect(fixture.model.selectedQuickExportURLs == [fixture.secondURL])
    }

    @Test func rejectingASingleFrameAdvancesTheOnlyVisibleSelection() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.rejectSelectedFrame()

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

        fixture.model.keepSelectedFrame()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.thirdURL)
        #expect(fixture.model.previewSelection(in: fixture.frames) == .single(fixture.thirdURL))
        #expect(fixture.model.selectedQuickExportURLs == [fixture.thirdURL])
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
}
