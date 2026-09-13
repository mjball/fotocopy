import Foundation

actor DuplicateChecker {
    private var existing: Set<String> = []
    private var manifest: DestinationManifest?

    func buildIndex(at destinationURL: URL) throws -> DestinationIndexStatus {
        let manifest = DestinationManifest(destinationURL: destinationURL)
        self.manifest = manifest

        let result = try manifest.prepareIndex()
        switch result.status {
        case .ready:
            existing = result.keys
            return .ready
        case let .requiresUserAction(attention):
            existing.removeAll()
            return .requiresUserAction(attention)
        }
    }

    func rebuildManifest(at destinationURL: URL) async throws -> DestinationIndexStatus {
        let manifest = DestinationManifest(destinationURL: destinationURL)
        self.manifest = manifest
        try await manifest.rebuildManifest()
        let result = try manifest.prepareIndex()
        switch result.status {
        case .ready:
            existing = result.keys
            return .ready
        case let .requiresUserAction(attention):
            existing.removeAll()
            return .requiresUserAction(attention)
        }
    }

    func isDuplicate(filename: String, size: Int, sourceBucket: String) -> Bool {
        existing.contains(makeDuplicateKey(filename: filename, size: size, sourceBucket: sourceBucket))
    }

    /// A completed preview owns a prepared checker. Before consuming that
    /// preview, make the cheap check that its manifest still exists instead of
    /// recursively reconciling the destination again. A later preview remains
    /// the point where Finder changes are fully audited.
    func ensureReadyForImport(at destinationURL: URL) throws {
        guard let manifest,
              manifest.destinationURL.standardizedFileURL == destinationURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: manifest.databaseURL.path) else {
            throw NSError(
                domain: "DuplicateChecker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Destination manifest changed after the preview. Rescan before importing."]
            )
        }
    }

    func markImported(
        filename: String,
        size: Int,
        sourceBucket: String,
        destinationRelativePath: String?,
        destinationSize: Int
    ) throws {
        existing.insert(makeDuplicateKey(filename: filename, size: size, sourceBucket: sourceBucket))

        if let manifest, let destinationRelativePath {
            try manifest.recordImport(
                destinationRelativePath: destinationRelativePath,
                sourceFilename: filename,
                sourceBucket: sourceBucket,
                sourceSize: size,
                destinationSize: destinationSize
            )
        }
    }
}
