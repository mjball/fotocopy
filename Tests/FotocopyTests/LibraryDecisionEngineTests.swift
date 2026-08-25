import Foundation
import Testing
@testable import Fotocopy

@Suite
struct LibraryDecisionEngineTests {
    private func makeTempDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-library-decisions-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createFile(_ url: URL, size: Int = 100) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: size).write(to: url)
    }

    private func decisionFolder(_ root: URL, disposition: CullDisposition, day: String = "22") -> URL {
        root
            .appendingPathComponent("2026")
            .appendingPathComponent("08")
            .appendingPathComponent(day)
            .appendingPathComponent(disposition.destinationFolderName)
    }

    @Test func scanFindsOnlyDirectDecisionCR3Packages() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let selects = decisionFolder(root, disposition: .select)
        let rejects = decisionFolder(root, disposition: .reject)
        let kept = selects.appendingPathComponent("BL5A0001.CR3")
        let rejected = rejects.appendingPathComponent("BL5A0002.CR3")
        try createFile(kept, size: 100)
        try createFile(kept.appendingPathExtension("on1"), size: 20)
        try createFile(kept.deletingPathExtension().appendingPathExtension("xmp"), size: 30)
        try createFile(rejected, size: 200)
        try createFile(root.appendingPathComponent("Exports/Rejects/NOT-A-DECISION.CR3"), size: 999)
        try createFile(rejects.appendingPathComponent("nested/NOT-DIRECT.CR3"), size: 999)
        try createFile(rejects.appendingPathComponent(".hidden.CR3"), size: 999)
        try FileManager.default.createSymbolicLink(
            at: rejects.appendingPathComponent("linked.CR3"),
            withDestinationURL: rejected
        )

        let scan = try LibraryDecisionEngine.scan(libraryRootURL: root)

        #expect(scan.decisions.count == 2)
        #expect(scan.keptCount == 1)
        #expect(scan.rejectedCount == 1)
        #expect(scan.totalBytes == 350)
        #expect(scan.decisions.first { $0.filename == kept.lastPathComponent }?.companionFileCount == 2)
        #expect(scan.decisions.allSatisfy { $0.dateLabel == "2026/08/22" })
    }

    @Test func trashPlanRevalidatesChangedPackageAndReportsPartialFailures() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let rejects = decisionFolder(root, disposition: .reject)
        let raw = rejects.appendingPathComponent("BL5A0002.CR3")
        let on1 = raw.appendingPathExtension("on1")
        try createFile(raw, size: 200)
        try createFile(on1, size: 20)
        let plan = try LibraryDecisionEngine.makeTrashPlan(libraryRootURL: root)

        var trashed: [URL] = []
        var recordedPaths: [String] = []
        let result = LibraryDecisionEngine.executeTrash(
            plan,
            trashItem: { url in
                trashed.append(url)
                if url == on1 { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "sidecar busy"]) }
            },
            recordDeletedPaths: { _, paths in recordedPaths = paths }
        )

        #expect(result.trashedPrimaryPhotoURLs.map(\.lastPathComponent) == [raw.lastPathComponent])
        #expect(result.trashedCompanionFileCount == 0)
        #expect(result.failures.count == 1)
        #expect(recordedPaths == ["2026/08/22/Rejects/BL5A0002.CR3"])
        #expect(trashed.map(\.lastPathComponent) == [raw.lastPathComponent, on1.lastPathComponent])

        try createFile(raw.deletingPathExtension().appendingPathExtension("xmp"), size: 15)
        var attemptedStaleTrash = false
        let staleResult = LibraryDecisionEngine.executeTrash(
            plan,
            trashItem: { _ in attemptedStaleTrash = true },
            recordDeletedPaths: { _, _ in }
        )
        #expect(!attemptedStaleTrash)
        #expect(staleResult.trashedPrimaryPhotoURLs.isEmpty)
        #expect(staleResult.failures.count == 1)
    }

    @Test func manifestFailureIsReportedAfterPhotoWasTrashed() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = decisionFolder(root, disposition: .reject).appendingPathComponent("BL5A0003.CR3")
        try createFile(raw)
        let plan = try LibraryDecisionEngine.makeTrashPlan(libraryRootURL: root)

        let result = LibraryDecisionEngine.executeTrash(
            plan,
            trashItem: { _ in },
            recordDeletedPaths: { _, _ in throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "manifest locked"]) }
        )

        #expect(result.trashedPrimaryPhotoURLs.map(\.lastPathComponent) == [raw.lastPathComponent])
        #expect(result.manifestError?.contains("manifest locked") == true)
    }
}
