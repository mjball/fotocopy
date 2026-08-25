import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullApplyEngineTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-cull-apply-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createFile(at url: URL, size: Int = 100) throws {
        try Data(repeating: 0x42, count: size).write(to: url)
    }

    @Test func applyMovesOnlyExplicitSelectsAndRejects() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let day = root
            .appendingPathComponent("2026")
            .appendingPathComponent("08")
            .appendingPathComponent("22")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let select = day.appendingPathComponent("BL5A0001.CR3")
        let reject = day.appendingPathComponent("BL5A0002.CR3")
        let unmarked = day.appendingPathComponent("BL5A0003.CR3")
        try createFile(at: select)
        try createFile(at: reject)
        try createFile(at: unmarked)

        let plan = try CullApplyEngine.makePlan(
            folderURL: day,
            dispositions: [select: .select, reject: .reject]
        )
        let result = try CullApplyEngine.apply(plan)

        #expect(result.selectCount == 1)
        #expect(result.rejectCount == 1)
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("Selects/BL5A0001.CR3").path))
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("Rejects/BL5A0002.CR3").path))
        #expect(FileManager.default.fileExists(atPath: unmarked.path))
    }

    @Test func applyMovesKnownSidecarsAlongsideRaw() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = root.appendingPathComponent("BL5A0001.CR3")
        let rawSidecar = raw.appendingPathExtension("on1")
        let xmpSidecar = raw.deletingPathExtension().appendingPathExtension("xmp")
        try createFile(at: raw)
        try createFile(at: rawSidecar)
        try createFile(at: xmpSidecar)

        let plan = try CullApplyEngine.makePlan(
            folderURL: root,
            dispositions: [raw: .select]
        )
        let result = try CullApplyEngine.apply(plan)

        #expect(result.companionFileCount == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Selects/BL5A0001.CR3").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Selects/BL5A0001.CR3.on1").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Selects/BL5A0001.xmp").path))
    }

    @Test func immediateRelocationCanReclassifyAndRestoreAFrame() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = root.appendingPathComponent("BL5A0001.CR3")
        let sidecar = raw.deletingPathExtension().appendingPathExtension("xmp")
        try createFile(at: raw)
        try createFile(at: sidecar)

        let selected = root.appendingPathComponent("Selects/BL5A0001.CR3")
        let rejected = root.appendingPathComponent("Rejects/BL5A0001.CR3")

        let selectPlan = try CullApplyEngine.makePlan(
            folderURL: root,
            rawRelocations: [CullFrameRelocation(sourceURL: raw, destinationURL: selected)]
        )
        let selectResult = try CullApplyEngine.apply(selectPlan)
        #expect(selectResult.rawRelocations == [
            CullFrameRelocation(sourceURL: raw.standardizedFileURL, destinationURL: selected.standardizedFileURL)
        ])
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(FileManager.default.fileExists(atPath: selected.deletingPathExtension().appendingPathExtension("xmp").path))

        let rejectPlan = try CullApplyEngine.makePlan(
            folderURL: root,
            rawRelocations: [CullFrameRelocation(sourceURL: selected, destinationURL: rejected)]
        )
        _ = try CullApplyEngine.apply(rejectPlan)
        #expect(FileManager.default.fileExists(atPath: rejected.path))
        #expect(!FileManager.default.fileExists(atPath: selected.path))

        let restorePlan = try CullApplyEngine.makePlan(
            folderURL: root,
            rawRelocations: [CullFrameRelocation(sourceURL: rejected, destinationURL: raw)]
        )
        _ = try CullApplyEngine.apply(restorePlan)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
    }

    @Test func applyUpdatesManifestWithoutLosingDuplicateProvenance() async throws {
        let destination = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: destination) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: destination) == .ready)

        let day = destination
            .appendingPathComponent("2026")
            .appendingPathComponent("08")
            .appendingPathComponent("22")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let raw = day.appendingPathComponent("BL5A0001.CR3")
        try createFile(at: raw, size: 250)
        try await checker.markImported(
            filename: "BL5A0001.CR3",
            size: 250,
            sourceBucket: "camera-card-1",
            destinationRelativePath: "2026/08/22/BL5A0001.CR3",
            destinationSize: 250
        )

        let plan = try CullApplyEngine.makePlan(
            folderURL: day,
            dispositions: [raw: .select]
        )
        _ = try CullApplyEngine.apply(plan)

        let selected = day.appendingPathComponent("Selects/BL5A0001.CR3")
        let restorePlan = try CullApplyEngine.makePlan(
            folderURL: day,
            rawRelocations: [CullFrameRelocation(sourceURL: selected, destinationURL: raw)]
        )
        _ = try CullApplyEngine.apply(restorePlan)

        #expect(try await checker.buildIndex(at: destination) == .ready)
        #expect(await checker.isDuplicate(
            filename: "BL5A0001.CR3",
            size: 250,
            sourceBucket: "camera-card-1"
        ))
    }

    @Test func applyRefusesToOverwriteExistingDestination() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = root.appendingPathComponent("BL5A0001.CR3")
        try createFile(at: raw)
        let selects = root.appendingPathComponent("Selects")
        try FileManager.default.createDirectory(at: selects, withIntermediateDirectories: true)
        try createFile(at: selects.appendingPathComponent("BL5A0001.CR3"))

        #expect(throws: CullApplyError.self) {
            try CullApplyEngine.makePlan(folderURL: root, dispositions: [raw: .select])
        }
        #expect(FileManager.default.fileExists(atPath: raw.path))
    }
}
