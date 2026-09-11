import Foundation
import Testing
@testable import Fotocopy

@Suite
@MainActor
struct CullDecisionSelectionSyncTests {
    @Test func keepingASingleFrameAdvancesTheFocusedFrameIndicator() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.keepSelectedFrame()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.secondURL)
        #expect(fixture.model.isFocusedFrame(fixture.secondURL))
        #expect(!fixture.model.isFocusedFrame(fixture.firstURL))
    }

    @Test func rejectingASingleFrameAdvancesTheFocusedFrameIndicator() async throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.rejectSelectedFrame()

        try await waitForDecisionAdvance(in: fixture.model, expectedFrameURL: fixture.secondURL)
        #expect(fixture.model.isFocusedFrame(fixture.secondURL))
        #expect(!fixture.model.isFocusedFrame(fixture.firstURL))
    }

    @Test func commandClickKeepsEveryExportSelectionVisibleWhileFocusMoves() throws {
        let fixture = try makeSingleFrameModel()
        defer { try? FileManager.default.removeItem(at: fixture.folderURL) }

        fixture.model.selectSingleFrame(fixture.firstURL)
        fixture.model.selectSingleFrame(fixture.secondURL, extendingQuickExportSelection: true)

        #expect(fixture.model.isQuickExportSelected(fixture.firstURL))
        #expect(fixture.model.isQuickExportSelected(fixture.secondURL))
        #expect(!fixture.model.isFocusedFrame(fixture.firstURL))
        #expect(fixture.model.isFocusedFrame(fixture.secondURL))
    }

    private func makeSingleFrameModel() throws -> (model: CullViewModel, folderURL: URL, firstURL: URL, secondURL: URL) {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fotocopy-CullDecisionSelectionSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let firstURL = folderURL.appendingPathComponent("IMG_0001.CR3")
        let secondURL = folderURL.appendingPathComponent("IMG_0002.CR3")
        FileManager.default.createFile(atPath: firstURL.path, contents: Data())
        FileManager.default.createFile(atPath: secondURL.path, contents: Data())

        let frames = [firstURL, secondURL].map { url in
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
        return (model, folderURL, firstURL, secondURL)
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
