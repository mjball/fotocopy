import Foundation
import SQLite3

func makeDuplicateKey(filename: String, size: Int, sourceBucket: String) -> String {
    "\(sourceBucket):\(filename):\(size)"
}

enum DestinationIndexStatus: Sendable, Equatable {
    case ready
    case requiresUserAction(ManifestAttention)
}

struct ManifestAttention: Sendable, Equatable {
    enum Kind: String, Sendable {
        case missingManifest
        case outOfSync
        case corruptManifest
    }

    let kind: Kind
    let destinationFileCount: Int
    let untrackedFileCount: Int
    let missingFileCount: Int
    let modifiedFileCount: Int
    let details: String?

    var title: String {
        switch kind {
        case .missingManifest:
            return "Build Destination Manifest"
        case .outOfSync:
            return "Destination Manifest Needs Rebuild"
        case .corruptManifest:
            return "Destination Manifest Is Unreadable"
        }
    }

    var actionLabel: String {
        switch kind {
        case .missingManifest:
            return "Build Manifest"
        case .outOfSync, .corruptManifest:
            return "Rebuild Manifest"
        }
    }

    var summary: String {
        switch kind {
        case .missingManifest:
            return "\(destinationFileCount) existing import(s)"
        case .outOfSync:
            var parts: [String] = []
            if untrackedFileCount > 0 {
                parts.append("\(untrackedFileCount) untracked")
            }
            if missingFileCount > 0 {
                parts.append("\(missingFileCount) missing")
            }
            if modifiedFileCount > 0 {
                parts.append("\(modifiedFileCount) updated")
            }
            return parts.isEmpty ? "Manifest mismatch detected" : parts.joined(separator: " • ")
        case .corruptManifest:
            return "Manifest could not be read"
        }
    }

    var importDisabledReason: String {
        switch kind {
        case .missingManifest:
            return "Destination manifest must be built before scanning"
        case .outOfSync:
            return "Destination manifest is out of sync with imported files"
        case .corruptManifest:
            return "Destination manifest must be rebuilt before scanning"
        }
    }

    var message: String {
        switch kind {
        case .missingManifest:
            return "This destination already has imported files, but Fotocopy does not have a manifest for them yet. Build it now so duplicate detection can distinguish repeated camera filenames by source folder."
        case .outOfSync:
            var parts: [String] = []
            if untrackedFileCount > 0 {
                parts.append("\(untrackedFileCount) file(s) exist on disk but are missing from the manifest")
            }
            if missingFileCount > 0 {
                parts.append("\(missingFileCount) manifest row(s) point to files that no longer exist")
            }
            if modifiedFileCount > 0 {
                parts.append("\(modifiedFileCount) file(s) changed size and will be refreshed")
            }
            let detailText = parts.isEmpty ? "The manifest no longer matches the destination files." : parts.joined(separator: "; ")
            return "Fotocopy found a manifest mismatch. \(detailText). Rebuild it before scanning so duplicate detection stays conservative and predictable."
        case .corruptManifest:
            let detailText = details ?? "The manifest could not be read."
            return "\(detailText) Rebuild the manifest before scanning."
        }
    }

    var confirmationMessage: String {
        switch kind {
        case .missingManifest:
            return "Build a SQLite manifest for this destination now? Fotocopy will scan the existing imports once, infer source folders for older files when needed, and use that manifest for future duplicate detection."
        case .outOfSync:
            return "Rebuild the SQLite manifest for this destination now? Fotocopy will rescan the destination, keep known source-folder identities when possible, add unmanaged files, remove entries for missing files, and refresh changed files."
        case .corruptManifest:
            return "Rebuild the SQLite manifest for this destination now? Fotocopy will rescan the destination and recreate the manifest from the files on disk."
        }
    }
}

struct ManifestLoadResult {
    let status: DestinationIndexStatus
    let keys: Set<String>
}

private struct ManifestRow {
    let destinationRelativePath: String
    let sourceFilename: String
    let sourceBucket: String
    let sourceSize: Int
    let destinationSizeLastSeen: Int
    let provenance: String
}

private struct DestinationFileSnapshot {
    let url: URL
    let relativePath: String
    let filename: String
    let size: Int
    let fileDate: Date?
}

private struct RebuildCandidate {
    let snapshot: DestinationFileSnapshot
    let sourceFilename: String
    let sortDate: Date?
}

struct DestinationManifest {
    static let metadataDirectoryName = "metadata"
    static let databaseFilename = "fotocopy-manifest.sqlite"
    static let photosLibraryBucket = "photos-library"
    static let rootBucket = "root"

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif",
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2",
        "mov", "mp4", "m4v"
    ]

    let destinationURL: URL

    var metadataDirectoryURL: URL {
        destinationURL.appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
    }

    var databaseURL: URL {
        metadataDirectoryURL.appendingPathComponent(Self.databaseFilename)
    }

    func loadIndex() throws -> DestinationIndexStatus {
        let result = try prepareIndex()
        return result.status
    }

    func duplicateKeys() throws -> Set<String> {
        try prepareIndex().keys
    }

    func prepareIndex() throws -> ManifestLoadResult {
        try loadIndexResult()
    }

    func rebuildManifest() async throws {
        let existingRows = try loadExistingRowsIfPossible()
        let snapshots = try enumerateDestinationFiles()
        let rows = try await buildRowsForRebuild(
            snapshots: snapshots,
            existingRowsByPath: existingRows
        )
        try writeRowsAtomically(rows)
    }

    func recordImport(
        destinationRelativePath: String,
        sourceFilename: String,
        sourceBucket: String,
        sourceSize: Int,
        destinationSize: Int
    ) throws {
        try FileManager.default.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)

        let db = try openDatabase(at: databaseURL)
        defer { sqlite3_close(db) }
        try ensureSchema(in: db)

        let sql = """
            INSERT INTO imports (
                destination_rel_path,
                source_filename,
                source_bucket,
                source_size,
                destination_size_last_seen,
                provenance,
                imported_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(destination_rel_path) DO UPDATE SET
                source_filename = excluded.source_filename,
                source_bucket = excluded.source_bucket,
                source_size = excluded.source_size,
                destination_size_last_seen = excluded.destination_size_last_seen,
                provenance = excluded.provenance,
                imported_at = excluded.imported_at
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to prepare manifest insert")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, destinationRelativePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sourceFilename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, sourceBucket, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, sqlite3_int64(sourceSize))
        sqlite3_bind_int64(stmt, 5, sqlite3_int64(destinationSize))
        sqlite3_bind_text(stmt, 6, "actual", -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw manifestError(db, fallback: "Failed to insert manifest row")
        }
    }

    private func loadIndexResult() throws -> ManifestLoadResult {
        let snapshots = try enumerateDestinationFiles()
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            if snapshots.isEmpty {
                try writeRowsAtomically([])
                return ManifestLoadResult(status: .ready, keys: [])
            }

            let attention = ManifestAttention(
                kind: .missingManifest,
                destinationFileCount: snapshots.count,
                untrackedFileCount: snapshots.count,
                missingFileCount: 0,
                modifiedFileCount: 0,
                details: nil
            )
            return ManifestLoadResult(status: .requiresUserAction(attention), keys: [])
        }

        do {
            let db = try openDatabase(at: databaseURL)
            defer { sqlite3_close(db) }
            try ensureSchema(in: db)

            let rows = try loadRows(from: db)
            let rowsByPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.destinationRelativePath, $0) })
            let snapshotsByPath = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.relativePath, $0) })

            let untracked = snapshotsByPath.keys.filter { rowsByPath[$0] == nil }
            let missing = rowsByPath.keys.filter { snapshotsByPath[$0] == nil }
            let modified = snapshotsByPath.compactMap { relativePath, snapshot -> (String, Int)? in
                guard let row = rowsByPath[relativePath],
                      row.destinationSizeLastSeen != snapshot.size else { return nil }
                return (relativePath, snapshot.size)
            }

            if !modified.isEmpty {
                try updateDestinationSizes(db: db, sizeUpdates: modified)
            }

            if !untracked.isEmpty || !missing.isEmpty {
                let attention = ManifestAttention(
                    kind: .outOfSync,
                    destinationFileCount: snapshots.count,
                    untrackedFileCount: untracked.count,
                    missingFileCount: missing.count,
                    modifiedFileCount: modified.count,
                    details: nil
                )
                return ManifestLoadResult(status: .requiresUserAction(attention), keys: [])
            }

            let keys = Set(rows.map {
                makeDuplicateKey(
                    filename: $0.sourceFilename,
                    size: $0.sourceSize,
                    sourceBucket: $0.sourceBucket
                )
            })
            return ManifestLoadResult(status: .ready, keys: keys)
        } catch {
            let attention = ManifestAttention(
                kind: .corruptManifest,
                destinationFileCount: snapshots.count,
                untrackedFileCount: 0,
                missingFileCount: 0,
                modifiedFileCount: 0,
                details: error.localizedDescription
            )
            return ManifestLoadResult(status: .requiresUserAction(attention), keys: [])
        }
    }

    private func loadExistingRowsIfPossible() throws -> [String: ManifestRow] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        do {
            let db = try openDatabase(at: databaseURL)
            defer { sqlite3_close(db) }
            try ensureSchema(in: db)
            return Dictionary(uniqueKeysWithValues: try loadRows(from: db).map { ($0.destinationRelativePath, $0) })
        } catch {
            return [:]
        }
    }

    private func buildRowsForRebuild(
        snapshots: [DestinationFileSnapshot],
        existingRowsByPath: [String: ManifestRow]
    ) async throws -> [ManifestRow] {
        let existingPaths = Set(snapshots.map(\.relativePath))
        var rows: [ManifestRow] = []
        rows.reserveCapacity(snapshots.count)

        let preservedRows = existingRowsByPath.values.filter { existingPaths.contains($0.destinationRelativePath) }
        let highestBucketNumber = preservedRows.compactMap { numericBucket(from: $0.sourceBucket) }.max() ?? 99

        for snapshot in snapshots {
            if let row = existingRowsByPath[snapshot.relativePath] {
                rows.append(
                    ManifestRow(
                        destinationRelativePath: row.destinationRelativePath,
                        sourceFilename: row.sourceFilename,
                        sourceBucket: row.sourceBucket,
                        sourceSize: row.sourceSize,
                        destinationSizeLastSeen: snapshot.size,
                        provenance: row.provenance
                    )
                )
            }
        }

        let unmanaged = snapshots.filter { existingRowsByPath[$0.relativePath] == nil }
        let inferred = try await inferRowsForUnmanagedFiles(
            snapshots: unmanaged,
            startingBucket: highestBucketNumber + 1
        )
        rows.append(contentsOf: inferred)
        return rows.sorted { $0.destinationRelativePath < $1.destinationRelativePath }
    }

    private func inferRowsForUnmanagedFiles(
        snapshots: [DestinationFileSnapshot],
        startingBucket: Int
    ) async throws -> [ManifestRow] {
        guard !snapshots.isEmpty else { return [] }

        let knownFilenames = Set(snapshots.map(\.filename))
        var candidates: [RebuildCandidate] = []
        candidates.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            let metadata = await EXIFDateReader.readMetadata(from: snapshot.url)
            let sortDate = metadata.dateResult?.date
                ?? dateFromDestinationPath(snapshot.relativePath)
                ?? snapshot.fileDate
            let sourceFilename = inferSourceFilename(
                from: snapshot.filename,
                knownFilenames: knownFilenames
            )
            candidates.append(
                RebuildCandidate(
                    snapshot: snapshot,
                    sourceFilename: sourceFilename,
                    sortDate: sortDate
                )
            )
        }

        let sorted = candidates.sorted { lhs, rhs in
            switch (lhs.sortDate, rhs.sortDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.snapshot.relativePath < rhs.snapshot.relativePath
            }
        }

        var currentBucket = max(startingBucket, 100)
        var seenInCurrentBucket: Set<String> = []
        var rows: [ManifestRow] = []
        rows.reserveCapacity(sorted.count)

        for candidate in sorted {
            if seenInCurrentBucket.contains(candidate.sourceFilename) {
                currentBucket += 1
                seenInCurrentBucket.removeAll()
            }

            seenInCurrentBucket.insert(candidate.sourceFilename)
            rows.append(
                ManifestRow(
                    destinationRelativePath: candidate.snapshot.relativePath,
                    sourceFilename: candidate.sourceFilename,
                    sourceBucket: String(format: "%03d", currentBucket),
                    sourceSize: candidate.snapshot.size,
                    destinationSizeLastSeen: candidate.snapshot.size,
                    provenance: "inferred"
                )
            )
        }

        return rows
    }

    private func enumerateDestinationFiles() throws -> [DestinationFileSnapshot] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: destinationURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let metadataPath = metadataDirectoryURL.standardizedFileURL.path
        var snapshots: [DestinationFileSnapshot] = []

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
            ) else { continue }

            if resourceValues.isDirectory == true {
                if fileURL.standardizedFileURL.path == metadataPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resourceValues.isRegularFile == true,
                  let size = resourceValues.fileSize else { continue }

            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }

            snapshots.append(
                DestinationFileSnapshot(
                    url: fileURL,
                    relativePath: relativePath(for: fileURL),
                    filename: fileURL.lastPathComponent,
                    size: size,
                    fileDate: resourceValues.creationDate ?? resourceValues.contentModificationDate
                )
            )
        }

        return snapshots
    }

    private func writeRowsAtomically(_ rows: [ManifestRow]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)

        let tempURL = metadataDirectoryURL.appendingPathComponent("fotocopy-manifest-\(UUID().uuidString).sqlite")
        defer { try? fm.removeItem(at: tempURL) }

        let db = try openDatabase(at: tempURL)
        defer { sqlite3_close(db) }
        try ensureSchema(in: db)
        try insertRows(rows, into: db)

        if fm.fileExists(atPath: databaseURL.path) {
            _ = try fm.replaceItemAt(databaseURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: databaseURL)
        }
    }

    private func insertRows(_ rows: [ManifestRow], into db: OpaquePointer?) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION", in: db)
        do {
            let sql = """
                INSERT INTO imports (
                    destination_rel_path,
                    source_filename,
                    source_bucket,
                    source_size,
                    destination_size_last_seen,
                    provenance,
                    imported_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw manifestError(db, fallback: "Failed to prepare manifest insert")
            }
            defer { sqlite3_finalize(stmt) }

            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, row.destinationRelativePath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, row.sourceFilename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, row.sourceBucket, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 4, sqlite3_int64(row.sourceSize))
                sqlite3_bind_int64(stmt, 5, sqlite3_int64(row.destinationSizeLastSeen))
                sqlite3_bind_text(stmt, 6, row.provenance, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw manifestError(db, fallback: "Failed to insert manifest row")
                }
            }

            try exec("COMMIT", in: db)
        } catch {
            try? exec("ROLLBACK", in: db)
            throw error
        }
    }

    private func updateDestinationSizes(
        db: OpaquePointer?,
        sizeUpdates: [(String, Int)]
    ) throws {
        let sql = """
            UPDATE imports
            SET destination_size_last_seen = ?
            WHERE destination_rel_path = ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to prepare manifest update")
        }
        defer { sqlite3_finalize(stmt) }

        for (relativePath, size) in sizeUpdates {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(size))
            sqlite3_bind_text(stmt, 2, relativePath, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw manifestError(db, fallback: "Failed to update manifest row")
            }
        }
    }

    private func loadRows(from db: OpaquePointer?) throws -> [ManifestRow] {
        let sql = """
            SELECT
                destination_rel_path,
                source_filename,
                source_bucket,
                source_size,
                destination_size_last_seen,
                provenance
            FROM imports
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to read manifest rows")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [ManifestRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let destinationPathPtr = sqlite3_column_text(stmt, 0),
                  let sourceFilenamePtr = sqlite3_column_text(stmt, 1),
                  let sourceBucketPtr = sqlite3_column_text(stmt, 2),
                  let provenancePtr = sqlite3_column_text(stmt, 5) else {
                continue
            }

            rows.append(
                ManifestRow(
                    destinationRelativePath: String(cString: destinationPathPtr),
                    sourceFilename: String(cString: sourceFilenamePtr),
                    sourceBucket: String(cString: sourceBucketPtr),
                    sourceSize: Int(sqlite3_column_int64(stmt, 3)),
                    destinationSizeLastSeen: Int(sqlite3_column_int64(stmt, 4)),
                    provenance: String(cString: provenancePtr)
                )
            )
        }
        return rows
    }

    private func ensureSchema(in db: OpaquePointer?) throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS imports (
                destination_rel_path TEXT PRIMARY KEY,
                source_filename TEXT NOT NULL,
                source_bucket TEXT NOT NULL,
                source_size INTEGER NOT NULL,
                destination_size_last_seen INTEGER NOT NULL,
                provenance TEXT NOT NULL,
                imported_at REAL NOT NULL
            )
            """, in: db)
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open manifest database"
            sqlite3_close(db)
            throw NSError(domain: "DestinationManifest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return db
    }

    private func exec(_ sql: String, in db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "SQLite command failed")
        }
    }

    private func manifestError(_ db: OpaquePointer?, fallback: String) -> NSError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? fallback
        return NSError(domain: "DestinationManifest", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func relativePath(for fileURL: URL) -> String {
        let destinationPath = destinationURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return String(filePath.dropFirst(destinationPath.count + 1))
    }

    private func dateFromDestinationPath(_ relativePath: String) -> Date? {
        let parts = relativePath.split(separator: "/")
        guard parts.count >= 4,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }

    private func inferSourceFilename(
        from destinationFilename: String,
        knownFilenames: Set<String>
    ) -> String {
        let ext = (destinationFilename as NSString).pathExtension
        let stem = (destinationFilename as NSString).deletingPathExtension
        guard let underscoreIndex = stem.lastIndex(of: "_"),
              let suffixNumber = Int(stem[stem.index(after: underscoreIndex)...]),
              suffixNumber >= 1 else {
            return destinationFilename
        }

        let baseStem = String(stem[..<underscoreIndex])
        let candidate = ext.isEmpty ? baseStem : "\(baseStem).\(ext)"
        return knownFilenames.contains(candidate) ? candidate : destinationFilename
    }

    private func numericBucket(from sourceBucket: String) -> Int? {
        let prefix = sourceBucket.prefix(3)
        guard prefix.count == 3, prefix.allSatisfy(\.isNumber) else { return nil }
        return Int(prefix)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
