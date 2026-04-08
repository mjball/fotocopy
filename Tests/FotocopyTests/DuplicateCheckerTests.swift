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
        let status = try await checker.buildIndex(at: dir)
        #expect(status == .ready)
        let result = await checker.isDuplicate(filename: "photo.jpg", size: 1000, sourceBucket: DestinationManifest.rootBucket)
        #expect(result == false)
    }

    @Test func indexesExistingFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        try createFile(dir, name: "photo.jpg", size: 1000)
        try await checker.markImported(
            filename: "photo.jpg",
            size: 1000,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: "photo.jpg",
            destinationSize: 1000
        )

        #expect(try await checker.buildIndex(at: dir) == .ready)
        let result = await checker.isDuplicate(
            filename: "photo.jpg",
            size: 1000,
            sourceBucket: DestinationManifest.rootBucket
        )
        #expect(result == true)
    }

    @Test func differentNameSameSize() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        try createFile(dir, name: "photo.jpg", size: 1000)
        try await checker.markImported(
            filename: "photo.jpg",
            size: 1000,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: "photo.jpg",
            destinationSize: 1000
        )

        let result = await checker.isDuplicate(
            filename: "other.jpg",
            size: 1000,
            sourceBucket: DestinationManifest.rootBucket
        )
        #expect(result == false)
    }

    @Test func sameNameDifferentSize() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        try createFile(dir, name: "photo.jpg", size: 1000)
        try await checker.markImported(
            filename: "photo.jpg",
            size: 1000,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: "photo.jpg",
            destinationSize: 1000
        )

        let result = await checker.isDuplicate(
            filename: "photo.jpg",
            size: 2000,
            sourceBucket: DestinationManifest.rootBucket
        )
        #expect(result == false)
    }

    @Test func markImported() async throws {
        let checker = DuplicateChecker()
        let before = await checker.isDuplicate(filename: "new.jpg", size: 500, sourceBucket: DestinationManifest.rootBucket)
        #expect(before == false)

        try await checker.markImported(
            filename: "new.jpg",
            size: 500,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: nil,
            destinationSize: 500
        )
        let after = await checker.isDuplicate(filename: "new.jpg", size: 500, sourceBucket: DestinationManifest.rootBucket)
        #expect(after == true)
    }

    @Test func hiddenFilesExcluded() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try createFile(dir, name: ".hidden.jpg", size: 1000)

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        let result = await checker.isDuplicate(filename: ".hidden.jpg", size: 1000, sourceBucket: DestinationManifest.rootBucket)
        #expect(result == false)
    }

    @Test func nonEmptyDestinationRequiresManifestRebuild() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let sub = dir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "nested.jpg", size: 750)

        let checker = DuplicateChecker()
        let status = try await checker.buildIndex(at: dir)
        #expect(status == .requiresUserAction(
            ManifestAttention(
                kind: .missingManifest,
                destinationFileCount: 1,
                untrackedFileCount: 1,
                missingFileCount: 0,
                modifiedFileCount: 0,
                details: nil
            )
        ))
    }

    @Test func rebuildClearsOldIndex() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer { cleanup(dir1); cleanup(dir2) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir1) == .ready)
        try createFile(dir1, name: "old.jpg", size: 100)
        try await checker.markImported(
            filename: "old.jpg",
            size: 100,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: "old.jpg",
            destinationSize: 100
        )
        #expect(await checker.isDuplicate(filename: "old.jpg", size: 100, sourceBucket: DestinationManifest.rootBucket) == true)

        #expect(try await checker.buildIndex(at: dir2) == .ready)
        #expect(await checker.isDuplicate(filename: "old.jpg", size: 100, sourceBucket: DestinationManifest.rootBucket) == false)
    }

    @Test func rebuildManifestInfersSequentialBucketsFromRepeatedNames() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let dayDir = dir
            .appendingPathComponent("2024")
            .appendingPathComponent("01")
            .appendingPathComponent("01")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try createFile(dayDir, name: "IMG_0001.CR3", size: 1000)
        try createFile(dayDir, name: "IMG_0001_1.CR3", size: 1000)

        let checker = DuplicateChecker()
        let status = try await checker.buildIndex(at: dir)
        #expect(status == .requiresUserAction(
            ManifestAttention(
                kind: .missingManifest,
                destinationFileCount: 2,
                untrackedFileCount: 2,
                missingFileCount: 0,
                modifiedFileCount: 0,
                details: nil
            )
        ))

        #expect(try await checker.rebuildManifest(at: dir) == .ready)
        #expect(await checker.isDuplicate(filename: "IMG_0001.CR3", size: 1000, sourceBucket: "100") == true)
        #expect(await checker.isDuplicate(filename: "IMG_0001.CR3", size: 1000, sourceBucket: "101") == true)
    }

    @Test func outOfSyncManifestRequiresReconcile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)

        try createFile(dir, name: "known.jpg", size: 100)
        try await checker.markImported(
            filename: "known.jpg",
            size: 100,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: "known.jpg",
            destinationSize: 100
        )

        try createFile(dir, name: "extra.jpg", size: 200)

        let status = try await checker.buildIndex(at: dir)
        #expect(status == .requiresUserAction(
            ManifestAttention(
                kind: .outOfSync,
                destinationFileCount: 2,
                untrackedFileCount: 1,
                missingFileCount: 0,
                modifiedFileCount: 0,
                details: nil
            )
        ))
    }
}
