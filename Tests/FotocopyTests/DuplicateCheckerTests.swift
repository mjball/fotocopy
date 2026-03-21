import Testing
import Foundation
@testable import Fotocopy

@Suite
struct DuplicateCheckerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func createFile(_ dir: URL, name: String, size: Int) throws {
        let data = Data(repeating: 0x41, count: size)
        try data.write(to: dir.appendingPathComponent(name))
    }

    @Test func emptyDirectory() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dir)
        let result = await checker.isDuplicate(filename: "photo.jpg", size: 1000)
        #expect(result == false)
    }

    @Test func indexesExistingFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try createFile(dir, name: "photo.jpg", size: 1000)

        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dir)
        let result = await checker.isDuplicate(filename: "photo.jpg", size: 1000)
        #expect(result == true)
    }

    @Test func differentNameSameSize() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try createFile(dir, name: "photo.jpg", size: 1000)

        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dir)
        let result = await checker.isDuplicate(filename: "other.jpg", size: 1000)
        #expect(result == false)
    }

    @Test func sameNameDifferentSize() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try createFile(dir, name: "photo.jpg", size: 1000)

        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dir)
        let result = await checker.isDuplicate(filename: "photo.jpg", size: 2000)
        #expect(result == false)
    }

    @Test func markImported() async throws {
        let checker = DuplicateChecker()
        let before = await checker.isDuplicate(filename: "new.jpg", size: 500)
        #expect(before == false)

        await checker.markImported(filename: "new.jpg", size: 500)
        let after = await checker.isDuplicate(filename: "new.jpg", size: 500)
        #expect(after == true)
    }

    @Test func hiddenFilesExcluded() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try createFile(dir, name: ".hidden.jpg", size: 1000)

        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dir)
        let result = await checker.isDuplicate(filename: ".hidden.jpg", size: 1000)
        #expect(result == false)
    }

    @Test func recursiveIndexing() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let sub = dir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "nested.jpg", size: 750)

        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dir)
        let result = await checker.isDuplicate(filename: "nested.jpg", size: 750)
        #expect(result == true)
    }

    @Test func rebuildClearsOldIndex() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer { cleanup(dir1); cleanup(dir2) }
        try createFile(dir1, name: "old.jpg", size: 100)

        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dir1)
        #expect(await checker.isDuplicate(filename: "old.jpg", size: 100) == true)

        try await checker.buildIndex(at: dir2)
        #expect(await checker.isDuplicate(filename: "old.jpg", size: 100) == false)
    }
}
