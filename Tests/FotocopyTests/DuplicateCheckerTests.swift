import Testing
import Foundation
import SQLite3
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

    private func manifestState(at dir: URL, relativePath: String) throws -> (sourceBucket: String, presence: String, lastSeenAt: Double, deletedAt: Double?) {
        let manifest = DestinationManifest(destinationURL: dir)
        var db: OpaquePointer?
        guard sqlite3_open_v2(manifest.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "DuplicateCheckerTests", code: 1)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT source_bucket, presence, last_seen_at, deleted_at FROM imports WHERE destination_rel_path = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DuplicateCheckerTests", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, relativePath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let sourceBucketPtr = sqlite3_column_text(stmt, 0),
              let presencePtr = sqlite3_column_text(stmt, 1) else {
            throw NSError(domain: "DuplicateCheckerTests", code: 3)
        }

        return (
            sourceBucket: String(cString: sourceBucketPtr),
            presence: String(cString: presencePtr),
            lastSeenAt: sqlite3_column_double(stmt, 2),
            deletedAt: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
        )
    }

    private func createLegacyManifest(at dir: URL, relativePath: String, size: Int) throws {
        let manifest = DestinationManifest(destinationURL: dir)
        try FileManager.default.createDirectory(at: manifest.metadataDirectoryURL, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open_v2(manifest.databaseURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "DuplicateCheckerTests", code: 4)
        }
        defer { sqlite3_close(db) }

        let sql = """
            CREATE TABLE imports (
                destination_rel_path TEXT PRIMARY KEY,
                source_filename TEXT NOT NULL,
                source_bucket TEXT NOT NULL,
                source_size INTEGER NOT NULL,
                destination_size_last_seen INTEGER NOT NULL,
                provenance TEXT NOT NULL,
                imported_at REAL NOT NULL
            );
            INSERT INTO imports VALUES ('\(relativePath)', 'legacy.jpg', 'root', \(size), \(size), 'actual', 123);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DuplicateCheckerTests", code: 5)
        }
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

    @Test func migratesLegacyManifestToTrackPresence() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        try createFile(dir, name: "legacy.jpg", size: 100)
        try createLegacyManifest(at: dir, relativePath: "legacy.jpg", size: 100)

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        #expect(await checker.isDuplicate(
            filename: "legacy.jpg",
            size: 100,
            sourceBucket: DestinationManifest.rootBucket
        ) == true)

        let state = try manifestState(at: dir, relativePath: "legacy.jpg")
        #expect(state.presence == "present")
        #expect(state.lastSeenAt == 123)
        #expect(state.deletedAt == nil)
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

    @Test func modifiedManifestRequiresRebuildAndRefreshesDuplicateKey() async throws {
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

        try createFile(dir, name: "known.jpg", size: 200)

        let status = try await checker.buildIndex(at: dir)
        #expect(status == .requiresUserAction(
            ManifestAttention(
                kind: .outOfSync,
                destinationFileCount: 1,
                untrackedFileCount: 0,
                missingFileCount: 0,
                modifiedFileCount: 1,
                details: nil
            )
        ))

        #expect(try await checker.rebuildManifest(at: dir) == .ready)
        #expect(await checker.isDuplicate(filename: "known.jpg", size: 100, sourceBucket: DestinationManifest.rootBucket) == false)
        #expect(await checker.isDuplicate(filename: "known.jpg", size: 200, sourceBucket: DestinationManifest.rootBucket) == true)
    }

    @Test func deletedDestinationFileRemainsDuplicate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)

        try createFile(dir, name: "deleted.jpg", size: 100)
        try await checker.markImported(
            filename: "deleted.jpg",
            size: 100,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: "deleted.jpg",
            destinationSize: 100
        )
        let importedState = try manifestState(at: dir, relativePath: "deleted.jpg")
        #expect(importedState.presence == "present")
        #expect(importedState.lastSeenAt > 0)
        #expect(importedState.deletedAt == nil)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("deleted.jpg"))

        #expect(try await checker.buildIndex(at: dir) == .ready)
        #expect(await checker.isDuplicate(
            filename: "deleted.jpg",
            size: 100,
            sourceBucket: DestinationManifest.rootBucket
        ) == true)

        let deletedState = try manifestState(at: dir, relativePath: "deleted.jpg")
        #expect(deletedState.presence == "deletedExternally")
        #expect(deletedState.lastSeenAt == importedState.lastSeenAt)
        #expect(deletedState.deletedAt != nil)

        try createFile(dir, name: "deleted.jpg", size: 100)
        #expect(try await checker.buildIndex(at: dir) == .ready)

        let restoredState = try manifestState(at: dir, relativePath: "deleted.jpg")
        #expect(restoredState.presence == "present")
        #expect(restoredState.deletedAt == nil)
        #expect(restoredState.lastSeenAt >= importedState.lastSeenAt)
    }

    @Test func rebuildPreservesDeletedDestinationFileHistory() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)

        try createFile(dir, name: "deleted.jpg", size: 100)
        try await checker.markImported(
            filename: "deleted.jpg",
            size: 100,
            sourceBucket: DestinationManifest.rootBucket,
            destinationRelativePath: "deleted.jpg",
            destinationSize: 100
        )
        try FileManager.default.removeItem(at: dir.appendingPathComponent("deleted.jpg"))

        #expect(try await checker.rebuildManifest(at: dir) == .ready)
        #expect(await checker.isDuplicate(
            filename: "deleted.jpg",
            size: 100,
            sourceBucket: DestinationManifest.rootBucket
        ) == true)
    }

    @Test func rebuildManifestPrefersEarliestCompatibleBucket() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let dayDir = dir
            .appendingPathComponent("2024")
            .appendingPathComponent("01")
            .appendingPathComponent("01")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try createFile(dayDir, name: "IMG_0001.CR3", size: 1000)
        try createFile(dayDir, name: "IMG_0001_1.CR3", size: 1000)
        try createFile(dayDir, name: "IMG_0002.CR3", size: 1200)

        let checker = DuplicateChecker()
        #expect(try await checker.rebuildManifest(at: dir) == .ready)

        #expect(await checker.isDuplicate(filename: "IMG_0001.CR3", size: 1000, sourceBucket: "100") == true)
        #expect(await checker.isDuplicate(filename: "IMG_0001.CR3", size: 1000, sourceBucket: "101") == true)
        #expect(await checker.isDuplicate(filename: "IMG_0002.CR3", size: 1200, sourceBucket: "100") == true)
        #expect(await checker.isDuplicate(filename: "IMG_0002.CR3", size: 1200, sourceBucket: "101") == false)
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

    @Test func automaticallyReconcilesFinderMoveWithinDateBucket() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let dateRoot = dir
            .appendingPathComponent("2026")
            .appendingPathComponent("08")
            .appendingPathComponent("22")
        let originalURL = dateRoot.appendingPathComponent("BL5A2471.CR3")

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        try FileManager.default.createDirectory(at: dateRoot, withIntermediateDirectories: true)
        try createFile(dateRoot, name: "BL5A2471.CR3", size: 100)

        try await checker.markImported(
            filename: "BL5A2471.CR3",
            size: 100,
            sourceBucket: "camera-card-1",
            destinationRelativePath: "2026/08/22/BL5A2471.CR3",
            destinationSize: 100
        )

        let selects = dateRoot.appendingPathComponent("Selects")
        try FileManager.default.createDirectory(at: selects, withIntermediateDirectories: true)
        let movedURL = selects.appendingPathComponent("BL5A2471.CR3")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        #expect(try await checker.buildIndex(at: dir) == .ready)
        #expect(await checker.isDuplicate(
            filename: "BL5A2471.CR3",
            size: 100,
            sourceBucket: "camera-card-1"
        ))

        let state = try manifestState(at: dir, relativePath: "2026/08/22/Selects/BL5A2471.CR3")
        #expect(state.sourceBucket == "camera-card-1")
        #expect(state.presence == "present")
        #expect(state.deletedAt == nil)
    }

    @Test func automaticallyReconcilesFinderMoveToAnySubfolderInDateBucket() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let dateRoot = dir
            .appendingPathComponent("2026")
            .appendingPathComponent("08")
            .appendingPathComponent("22")
        let originalURL = dateRoot.appendingPathComponent("BL5A2471.CR3")

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        try FileManager.default.createDirectory(at: dateRoot, withIntermediateDirectories: true)
        try createFile(dateRoot, name: "BL5A2471.CR3", size: 100)

        try await checker.markImported(
            filename: "BL5A2471.CR3",
            size: 100,
            sourceBucket: "camera-card-1",
            destinationRelativePath: "2026/08/22/BL5A2471.CR3",
            destinationSize: 100
        )

        let alternate = dateRoot
            .appendingPathComponent("Favorites")
            .appendingPathComponent("Birds")
        let movedURL = alternate.appendingPathComponent("BL5A2471.CR3")
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        #expect(try await checker.buildIndex(at: dir) == .ready)
        let state = try manifestState(at: dir, relativePath: "2026/08/22/Favorites/Birds/BL5A2471.CR3")
        #expect(state.sourceBucket == "camera-card-1")
        #expect(state.presence == "present")
    }

    @Test func doesNotReconcileFinderMoveAcrossDateBuckets() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let originalDateRoot = dir
            .appendingPathComponent("2026")
            .appendingPathComponent("08")
            .appendingPathComponent("22")
        let originalURL = originalDateRoot.appendingPathComponent("BL5A2471.CR3")

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dir) == .ready)
        try FileManager.default.createDirectory(at: originalDateRoot, withIntermediateDirectories: true)
        try createFile(originalDateRoot, name: "BL5A2471.CR3", size: 100)
        try await checker.markImported(
            filename: "BL5A2471.CR3",
            size: 100,
            sourceBucket: "camera-card-1",
            destinationRelativePath: "2026/08/22/BL5A2471.CR3",
            destinationSize: 100
        )

        let otherDateRoot = dir
            .appendingPathComponent("2026")
            .appendingPathComponent("08")
            .appendingPathComponent("23")
        try FileManager.default.createDirectory(at: otherDateRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalURL, to: otherDateRoot.appendingPathComponent("BL5A2471.CR3"))

        #expect(try await checker.buildIndex(at: dir) == .requiresUserAction(
            ManifestAttention(
                kind: .outOfSync,
                destinationFileCount: 1,
                untrackedFileCount: 1,
                missingFileCount: 1,
                modifiedFileCount: 0,
                details: nil
            )
        ))
    }
}
