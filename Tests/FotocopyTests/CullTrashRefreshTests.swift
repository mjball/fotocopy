import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullTrashRefreshTests {
    @Test @MainActor func successfulTrashRebuildsTheActiveCullFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-cull-trash-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let day = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("09", isDirectory: true)
            .appendingPathComponent("11", isDirectory: true)
        let remainingFrame = day.appendingPathComponent("BL5A0001.CR3")
        let trashedFrame = day
            .appendingPathComponent("Rejects", isDirectory: true)
            .appendingPathComponent("BL5A0002.CR3")
        try FileManager.default.createDirectory(
            at: trashedFrame.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: remainingFrame)
        try Data([0]).write(to: trashedFrame)

        let model = CullViewModel()
        model.folderURL = day
        try FileManager.default.removeItem(at: trashedFrame)
        let result = CullLibraryTrashResult(
            trashedPrimaryPhotoURLs: [trashedFrame],
            trashedCompanionFileCount: 0,
            failures: [],
            manifestError: nil
        )

        model.library.onRejectedPhotosTrashed?(result)
        #expect(model.isScanning)

        for _ in 0..<200 where model.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!model.isScanning)
        #expect(model.scanResult?.cr3Count == 1)
        #expect(
            model.selectedFrameURL?.resolvingSymlinksInPath()
                == remainingFrame.resolvingSymlinksInPath()
        )
        #expect(model.cullRefreshNotice == "1 rejected photo moved to Finder’s Trash. Cull refreshed.")
    }
}
