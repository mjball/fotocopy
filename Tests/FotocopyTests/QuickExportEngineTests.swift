import Foundation
import Testing
@testable import Fotocopy

@Suite
struct QuickExportEngineTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-quick-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func planCreatesJPEGDestinationsForEveryDistinctSelectedRaw() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportFolder = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("IMG_0001.CR3")
        let second = root.appendingPathComponent("IMG_0002.cr3")
        try Data().write(to: first)
        try Data().write(to: second)

        let plan = try QuickExportEngine.makePlan(
            sourceURLs: [first, second, first],
            destinationFolderURL: exportFolder
        )

        #expect(plan.items.map(\.destinationURL) == [
            exportFolder.appendingPathComponent("IMG_0001.jpg"),
            exportFolder.appendingPathComponent("IMG_0002.jpg")
        ])
    }

    @Test func planRefusesToOverwriteExistingJPEG() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("IMG_0001.CR3")
        let existingJPEG = root.appendingPathComponent("IMG_0001.jpg")
        try Data().write(to: raw)
        try Data().write(to: existingJPEG)

        #expect(throws: QuickExportError.self) {
            try QuickExportEngine.makePlan(sourceURLs: [raw], destinationFolderURL: root)
        }
    }

    @Test func exportContinuesAfterOneConverterFailure() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("IMG_0001.CR3")
        let second = root.appendingPathComponent("IMG_0002.CR3")
        try Data().write(to: first)
        try Data().write(to: second)
        let plan = try QuickExportEngine.makePlan(sourceURLs: [first, second], destinationFolderURL: root)

        let result = QuickExportEngine.export(plan) { source, destination in
            if source == first { throw TestError.failed }
            try Data("jpeg".utf8).write(to: destination)
        }

        #expect(result.failures.map(\.sourceURL) == [first.standardizedFileURL])
        #expect(result.exportedURLs == [root.appendingPathComponent("IMG_0002.jpg")])
    }

    private enum TestError: LocalizedError {
        case failed
        var errorDescription: String? { "Test conversion failure" }
    }
}
