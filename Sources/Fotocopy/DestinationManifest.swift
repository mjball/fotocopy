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
            return "Rebuild the SQLite manifest for this destination now? Fotocopy will rescan the destination, keep known source-folder identities and history for deleted files, add unmanaged files, and refresh changed files."
        case .corruptManifest:
            return "Rebuild the SQLite manifest for this destination now? Fotocopy will rescan the destination and recreate the manifest from the files on disk."
        }
    }
}

struct ManifestLoadResult {
    let status: DestinationIndexStatus
    let keys: Set<String>
}

struct DestinationManifestRelocation: Sendable, Hashable {
    let previousRelativePath: String
    let currentRelativePath: String
    let destinationSize: Int
}

private enum ManifestPresence: String {
    case present
    case deletedExternally
}

private struct ManifestRow {
    let destinationRelativePath: String
    let sourceFilename: String
    let sourceBucket: String
    let sourceSize: Int
    let destinationSizeLastSeen: Int
    let provenance: String
    let presence: ManifestPresence
    let lastSeenAt: TimeInterval
    let deletedAt: TimeInterval?
}

private struct DestinationFileSnapshot {
    let url: URL
    let relativePath: String
    let filename: String
    let size: Int
    let fileDate: Date?
}

/// Fotocopy makes each stored filename unique within a date bucket before it
/// imports. That makes this a stable, user-visible identity for moving a file
/// anywhere beneath the same date folder in Finder.
private struct DateScopedFileIdentity: Hashable {
    let dateBucket: String
    let filename: String
}

private struct ManifestMoveReconciliation {
    let previousRelativePath: String
    let snapshot: DestinationFileSnapshot
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

    private static let supportedExtensions = LibraryDecisionEngine.supportedStillImageExtensions.union([
        "mov", "mp4", "m4v"
    ])

    let destinationURL: URL

    var metadataDirectoryURL: URL {
        destinationURL.appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
    }

    var databaseURL: URL {
        metadataDirectoryURL.appendingPathComponent(Self.databaseFilename)
    }

    /// Finds the nearest Fotocopy destination root that already owns a
    /// manifest. Cull uses this before moving files so an applied decision can
    /// update the same manifest immediately instead of waiting for a later
    /// import scan to reconcile it.
    static func existingManifestRoot(containing folderURL: URL) -> URL? {
        let fm = FileManager.default
        var candidate = folderURL.standardizedFileURL

        while true {
            let databaseURL = candidate
                .appendingPathComponent(metadataDirectoryName, isDirectory: true)
                .appendingPathComponent(databaseFilename)
            if fm.fileExists(atPath: databaseURL.path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            // Foundation can represent the root as both `/` and `/.`; using
            // path length as well prevents those equivalent spellings from
            // making this ancestor walk cycle forever.
            guard parent.path.count < candidate.path.count else { return nil }
            candidate = parent
        }
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
                imported_at,
                presence,
                last_seen_at,
                deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(destination_rel_path) DO UPDATE SET
                source_filename = excluded.source_filename,
                source_bucket = excluded.source_bucket,
                source_size = excluded.source_size,
                destination_size_last_seen = excluded.destination_size_last_seen,
                provenance = excluded.provenance,
                imported_at = excluded.imported_at,
                presence = excluded.presence,
                last_seen_at = excluded.last_seen_at,
                deleted_at = NULL
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
        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(stmt, 7, now)
        sqlite3_bind_text(stmt, 8, ManifestPresence.present.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 9, now)
        sqlite3_bind_null(stmt, 10)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw manifestError(db, fallback: "Failed to insert manifest row")
        }
    }

    func validateRelocations(_ relocations: [DestinationManifestRelocation]) throws {
        guard !relocations.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw NSError(
                domain: "DestinationManifest",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Fotocopy's destination manifest is unavailable"]
            )
        }

        let db = try openDatabase(at: databaseURL)
        defer { sqlite3_close(db) }
        try ensureSchema(in: db)
        try validateRelocations(relocations, in: db)
    }

    func recordRelocations(_ relocations: [DestinationManifestRelocation]) throws {
        guard !relocations.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw NSError(
                domain: "DestinationManifest",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Fotocopy's destination manifest is unavailable"]
            )
        }

        let db = try openDatabase(at: databaseURL)
        defer { sqlite3_close(db) }
        try ensureSchema(in: db)

        let sql = """
            UPDATE imports
            SET destination_rel_path = ?,
                destination_size_last_seen = ?,
                presence = ?,
                last_seen_at = ?,
                deleted_at = NULL
            WHERE destination_rel_path = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to prepare manifest relocation")
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        try exec("BEGIN IMMEDIATE TRANSACTION", in: db)
        do {
            try validateRelocations(relocations, in: db)
            for relocation in relocations {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, relocation.currentRelativePath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, sqlite3_int64(relocation.destinationSize))
                sqlite3_bind_text(stmt, 3, ManifestPresence.present.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 4, now)
                sqlite3_bind_text(stmt, 5, relocation.previousRelativePath, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw manifestError(db, fallback: "Failed to record manifest relocation")
                }
            }
            try exec("COMMIT", in: db)
        } catch {
            try? exec("ROLLBACK", in: db)
            throw error
        }
    }

    /// Records known destination files that Fotocopy has sent to Finder's
    /// Trash. Their duplicate history intentionally remains in the manifest,
    /// so restoring or re-importing a repeated camera filename stays
    /// conservative.
    func recordDeletedPaths(_ relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw NSError(
                domain: "DestinationManifest",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Fotocopy's destination manifest is unavailable"]
            )
        }

        let db = try openDatabase(at: databaseURL)
        defer { sqlite3_close(db) }
        try ensureSchema(in: db)
        try updatePresence(in: db, deletedPaths: relativePaths, restoredPaths: [])
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

            // A Finder move anywhere within the same date folder preserves the
            // unique stored filename. Reconcile those one-to-one matches before
            // treating either path as out of sync. Any ambiguous move remains
            // in the existing conservative flow.
            let reconciliations = findReconcilableMoves(
                rowsByPath: rowsByPath,
                snapshotsByPath: snapshotsByPath
            )
            try reconcileMoves(in: db, reconciliations: reconciliations)
            let reconciledPreviousPaths = Set(reconciliations.map(\.previousRelativePath))
            let reconciledCurrentPaths = Set(reconciliations.map { $0.snapshot.relativePath })

            let untracked = snapshotsByPath.keys.filter {
                rowsByPath[$0] == nil && !reconciledCurrentPaths.contains($0)
            }
            let missing = rowsByPath.keys.filter {
                snapshotsByPath[$0] == nil && !reconciledPreviousPaths.contains($0)
            }
            let newlyDeleted = missing.filter {
                rowsByPath[$0]?.presence != .deletedExternally
            }
            let restored = snapshotsByPath.keys.filter {
                rowsByPath[$0]?.presence == .deletedExternally
            }
            let modified = snapshotsByPath.compactMap { relativePath, snapshot -> (String, Int)? in
                guard let row = rowsByPath[relativePath],
                      row.destinationSizeLastSeen != snapshot.size else { return nil }
                return (relativePath, snapshot.size)
            }

            try updatePresence(
                in: db,
                deletedPaths: newlyDeleted,
                restoredPaths: restored
            )

            // Missing destination files remain in the manifest as import history. This
            // prevents a file deleted in Finder from being imported again later.
            if !untracked.isEmpty || !modified.isEmpty {
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
        let snapshotsByPath = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.relativePath, $0) })
        let existingRowsByPath = reconciledRowsByPath(
            existingRowsByPath,
            snapshotsByPath: snapshotsByPath
        )
        let existingPaths = Set(snapshots.map(\.relativePath))
        var rows: [ManifestRow] = []
        rows.reserveCapacity(snapshots.count)

        let preservedRows = Array(existingRowsByPath.values)
        let highestBucketNumber = preservedRows.compactMap { numericBucket(from: $0.sourceBucket) }.max() ?? 99
        let now = Date().timeIntervalSince1970

        for snapshot in snapshots {
            if let row = existingRowsByPath[snapshot.relativePath] {
                let refreshedSize = snapshot.size
                rows.append(
                    ManifestRow(
                        destinationRelativePath: row.destinationRelativePath,
                        sourceFilename: row.sourceFilename,
                        sourceBucket: row.sourceBucket,
                        sourceSize: refreshedSize,
                        destinationSizeLastSeen: refreshedSize,
                        provenance: row.provenance,
                        presence: .present,
                        lastSeenAt: now,
                        deletedAt: nil
                    )
                )
            }
        }

        // Retain rows without a matching file as explicit tombstones so their
        // source files remain duplicates even after Finder deletion.
        rows.append(contentsOf: preservedRows.filter {
            !existingPaths.contains($0.destinationRelativePath)
        }.map { row in
            ManifestRow(
                destinationRelativePath: row.destinationRelativePath,
                sourceFilename: row.sourceFilename,
                sourceBucket: row.sourceBucket,
                sourceSize: row.sourceSize,
                destinationSizeLastSeen: row.destinationSizeLastSeen,
                provenance: row.provenance,
                presence: .deletedExternally,
                lastSeenAt: row.lastSeenAt,
                deletedAt: row.deletedAt ?? now
            )
        })

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

        let initialBucket = max(startingBucket, 100)
        var filenamesByBucket: [Set<String>] = []
        var rows: [ManifestRow] = []
        rows.reserveCapacity(sorted.count)

        for candidate in sorted {
            let bucketIndex: Int
            if let existingBucketIndex = filenamesByBucket.firstIndex(where: { !$0.contains(candidate.sourceFilename) }) {
                bucketIndex = existingBucketIndex
            } else {
                bucketIndex = filenamesByBucket.count
                filenamesByBucket.append([])
            }

            filenamesByBucket[bucketIndex].insert(candidate.sourceFilename)
            rows.append(
                ManifestRow(
                    destinationRelativePath: candidate.snapshot.relativePath,
                    sourceFilename: candidate.sourceFilename,
                    sourceBucket: String(format: "%03d", initialBucket + bucketIndex),
                    sourceSize: candidate.snapshot.size,
                    destinationSizeLastSeen: candidate.snapshot.size,
                    provenance: "inferred",
                    presence: .present,
                    lastSeenAt: Date().timeIntervalSince1970,
                    deletedAt: nil
                )
            )
        }

        return rows
    }

    private func enumerateDestinationFiles() throws -> [DestinationFileSnapshot] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: "DestinationManifest",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Destination folder is unavailable"]
            )
        }
        guard let enumerator = fm.enumerator(
            at: destinationURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let metadataPath = metadataDirectoryURL.standardizedFileURL.path
        var snapshots: [DestinationFileSnapshot] = []

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
            )

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

    private func findReconcilableMoves(
        rowsByPath: [String: ManifestRow],
        snapshotsByPath: [String: DestinationFileSnapshot]
    ) -> [ManifestMoveReconciliation] {
        let missingRows = rowsByPath.values.filter {
            snapshotsByPath[$0.destinationRelativePath] == nil
        }
        let untrackedSnapshots = snapshotsByPath.values.filter {
            rowsByPath[$0.relativePath] == nil
        }

        let missingByIdentity = Dictionary(grouping: missingRows, by: {
            dateScopedIdentity(for: $0.destinationRelativePath)
        })
        let untrackedByIdentity = Dictionary(grouping: untrackedSnapshots, by: {
            dateScopedIdentity(for: $0.relativePath)
        })

        var reconciliations: [ManifestMoveReconciliation] = []
        for (identity, candidates) in missingByIdentity {
            guard let identity,
                  candidates.count == 1,
                  let snapshots = untrackedByIdentity[identity],
                  snapshots.count == 1,
                  let row = candidates.first,
                  let snapshot = snapshots.first,
                  // A Finder move leaves the file unchanged. Treat a changed
                  // file as an out-of-sync condition rather than a move.
                  row.destinationSizeLastSeen == snapshot.size else {
                continue
            }
            reconciliations.append(
                ManifestMoveReconciliation(
                    previousRelativePath: row.destinationRelativePath,
                    snapshot: snapshot
                )
            )
        }
        return reconciliations
    }

    private func reconciledRowsByPath(
        _ existingRowsByPath: [String: ManifestRow],
        snapshotsByPath: [String: DestinationFileSnapshot]
    ) -> [String: ManifestRow] {
        let reconciliations = findReconcilableMoves(
            rowsByPath: existingRowsByPath,
            snapshotsByPath: snapshotsByPath
        )
        guard !reconciliations.isEmpty else { return existingRowsByPath }

        let now = Date().timeIntervalSince1970
        var reconciled = existingRowsByPath
        for reconciliation in reconciliations {
            guard let row = reconciled.removeValue(forKey: reconciliation.previousRelativePath) else {
                continue
            }
            reconciled[reconciliation.snapshot.relativePath] = ManifestRow(
                destinationRelativePath: reconciliation.snapshot.relativePath,
                sourceFilename: row.sourceFilename,
                sourceBucket: row.sourceBucket,
                sourceSize: row.sourceSize,
                destinationSizeLastSeen: reconciliation.snapshot.size,
                provenance: row.provenance,
                presence: .present,
                lastSeenAt: now,
                deletedAt: nil
            )
        }
        return reconciled
    }

    private func reconcileMoves(
        in db: OpaquePointer?,
        reconciliations: [ManifestMoveReconciliation]
    ) throws {
        guard !reconciliations.isEmpty else { return }

        let sql = """
            UPDATE imports
            SET destination_rel_path = ?,
                destination_size_last_seen = ?,
                presence = ?,
                last_seen_at = ?,
                deleted_at = NULL
            WHERE destination_rel_path = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to prepare Finder move reconciliation")
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        try exec("BEGIN IMMEDIATE TRANSACTION", in: db)
        do {
            for reconciliation in reconciliations {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, reconciliation.snapshot.relativePath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, sqlite3_int64(reconciliation.snapshot.size))
                sqlite3_bind_text(stmt, 3, ManifestPresence.present.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 4, now)
                sqlite3_bind_text(stmt, 5, reconciliation.previousRelativePath, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw manifestError(db, fallback: "Failed to reconcile Finder move")
                }
            }
            try exec("COMMIT", in: db)
        } catch {
            try? exec("ROLLBACK", in: db)
            throw error
        }
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
                    imported_at,
                    presence,
                    last_seen_at,
                    deleted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                sqlite3_bind_text(stmt, 8, row.presence.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 9, row.lastSeenAt)
                if let deletedAt = row.deletedAt {
                    sqlite3_bind_double(stmt, 10, deletedAt)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }

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

    private func loadRows(from db: OpaquePointer?) throws -> [ManifestRow] {
        let sql = """
            SELECT
                destination_rel_path,
                source_filename,
                source_bucket,
                source_size,
                destination_size_last_seen,
                provenance,
                presence,
                last_seen_at,
                deleted_at
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
                  let provenancePtr = sqlite3_column_text(stmt, 5),
                  let presencePtr = sqlite3_column_text(stmt, 6),
                  let presence = ManifestPresence(rawValue: String(cString: presencePtr)) else {
                continue
            }

            rows.append(
                ManifestRow(
                    destinationRelativePath: String(cString: destinationPathPtr),
                    sourceFilename: String(cString: sourceFilenamePtr),
                    sourceBucket: String(cString: sourceBucketPtr),
                    sourceSize: Int(sqlite3_column_int64(stmt, 3)),
                    destinationSizeLastSeen: Int(sqlite3_column_int64(stmt, 4)),
                    provenance: String(cString: provenancePtr),
                    presence: presence,
                    lastSeenAt: sqlite3_column_double(stmt, 7),
                    deletedAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_double(stmt, 8)
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
                imported_at REAL NOT NULL,
                presence TEXT NOT NULL DEFAULT 'present',
                last_seen_at REAL NOT NULL,
                deleted_at REAL
            )
            """, in: db)

        if try !hasColumn(named: "presence", in: db) {
            try exec("ALTER TABLE imports ADD COLUMN presence TEXT NOT NULL DEFAULT 'present'", in: db)
        }
        if try !hasColumn(named: "last_seen_at", in: db) {
            try exec("ALTER TABLE imports ADD COLUMN last_seen_at REAL", in: db)
            try exec("UPDATE imports SET last_seen_at = imported_at WHERE last_seen_at IS NULL", in: db)
        }
        if try !hasColumn(named: "deleted_at", in: db) {
            try exec("ALTER TABLE imports ADD COLUMN deleted_at REAL", in: db)
        }
    }

    private func updatePresence(
        in db: OpaquePointer?,
        deletedPaths: [String],
        restoredPaths: [String]
    ) throws {
        guard !deletedPaths.isEmpty || !restoredPaths.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        try exec("BEGIN IMMEDIATE TRANSACTION", in: db)
        do {
            if !deletedPaths.isEmpty {
                try updateRows(
                    in: db,
                    sql: "UPDATE imports SET presence = ?, deleted_at = ? WHERE destination_rel_path = ?",
                    paths: deletedPaths
                ) { stmt, path in
                    sqlite3_bind_text(stmt, 1, ManifestPresence.deletedExternally.rawValue, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 2, now)
                    sqlite3_bind_text(stmt, 3, path, -1, SQLITE_TRANSIENT)
                }
            }
            if !restoredPaths.isEmpty {
                try updateRows(
                    in: db,
                    sql: "UPDATE imports SET presence = ?, last_seen_at = ?, deleted_at = NULL WHERE destination_rel_path = ?",
                    paths: restoredPaths
                ) { stmt, path in
                    sqlite3_bind_text(stmt, 1, ManifestPresence.present.rawValue, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 2, now)
                    sqlite3_bind_text(stmt, 3, path, -1, SQLITE_TRANSIENT)
                }
            }
            try exec("COMMIT", in: db)
        } catch {
            try? exec("ROLLBACK", in: db)
            throw error
        }
    }

    private func updateRows(
        in db: OpaquePointer?,
        sql: String,
        paths: [String],
        bind: (OpaquePointer?, String) -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to update manifest presence")
        }
        defer { sqlite3_finalize(stmt) }

        for path in paths {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(stmt, path)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw manifestError(db, fallback: "Failed to update manifest presence")
            }
        }
    }

    private func validateRelocations(
        _ relocations: [DestinationManifestRelocation],
        in db: OpaquePointer?
    ) throws {
        var sourceStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM imports WHERE destination_rel_path = ?",
            -1,
            &sourceStatement,
            nil
        ) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to validate manifest relocation source")
        }
        defer { sqlite3_finalize(sourceStatement) }

        var destinationStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM imports WHERE destination_rel_path = ?",
            -1,
            &destinationStatement,
            nil
        ) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to validate manifest relocation destination")
        }
        defer { sqlite3_finalize(destinationStatement) }

        for relocation in relocations {
            guard relocation.previousRelativePath != relocation.currentRelativePath else { continue }

            sqlite3_reset(sourceStatement)
            sqlite3_clear_bindings(sourceStatement)
            sqlite3_bind_text(sourceStatement, 1, relocation.previousRelativePath, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(sourceStatement) == SQLITE_ROW else {
                throw NSError(
                    domain: "DestinationManifest",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Fotocopy has no manifest entry for \(relocation.previousRelativePath). Rebuild the destination manifest before applying this cull decision."]
                )
            }

            sqlite3_reset(destinationStatement)
            sqlite3_clear_bindings(destinationStatement)
            sqlite3_bind_text(destinationStatement, 1, relocation.currentRelativePath, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(destinationStatement) != SQLITE_ROW else {
                throw NSError(
                    domain: "DestinationManifest",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "The destination path \(relocation.currentRelativePath) is already recorded in Fotocopy's manifest."]
                )
            }
        }
    }

    private func hasColumn(named column: String, in db: OpaquePointer?) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(imports)", -1, &stmt, nil) == SQLITE_OK else {
            throw manifestError(db, fallback: "Failed to inspect manifest schema")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1), String(cString: namePtr) == column {
                return true
            }
        }
        return false
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

    private func dateScopedIdentity(for relativePath: String) -> DateScopedFileIdentity? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              year >= 0,
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }

        guard let filename = parts.last, !filename.isEmpty else { return nil }
        return DateScopedFileIdentity(
            dateBucket: String(parts[0...2].joined(separator: "/")),
            filename: String(filename)
        )
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
