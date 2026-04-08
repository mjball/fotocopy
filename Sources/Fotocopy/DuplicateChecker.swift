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
