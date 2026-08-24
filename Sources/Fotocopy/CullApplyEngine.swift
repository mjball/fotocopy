import Foundation

/// A cull decision is deliberately explicit. Frames without one stay in the
/// date folder; Fotocopy never infers a reject from an unmarked frame.
enum CullDisposition: String, Sendable, Hashable, CaseIterable {
    case select
    case reject

    var destinationFolderName: String {
        switch self {
        case .select: return "Selects"
        case .reject: return "Rejects"
        }
    }

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .reject: return "Reject"
        }
    }
}

struct CullApplyPlan: Sendable {
    let folderURL: URL
    let selectCount: Int
    let rejectCount: Int
    let companionFileCount: Int

    fileprivate let fileMoves: [CullApplyFileMove]
    fileprivate let manifestRootURL: URL?
    fileprivate let manifestRelocations: [DestinationManifestRelocation]

    var markedFrameCount: Int { selectCount + rejectCount }
}

struct CullApplyResult: Sendable, Equatable {
    let selectCount: Int
    let rejectCount: Int
    let companionFileCount: Int

    var markedFrameCount: Int { selectCount + rejectCount }
}

enum CullApplyError: LocalizedError {
    case noMarkedFrames
    case sourceOutsideReviewFolder(URL)
    case sourceUnavailable(URL)
    case destinationAlreadyExists(URL)
    case duplicateDestination(URL)

    var errorDescription: String? {
        switch self {
        case .noMarkedFrames:
            return "Mark at least one frame as a select or reject before applying changes."
        case .sourceOutsideReviewFolder(let url):
            return "\(url.lastPathComponent) is no longer in the folder being reviewed. Scan again before applying changes."
        case .sourceUnavailable(let url):
            return "\(url.lastPathComponent) is no longer available. Scan again before applying changes."
        case .destinationAlreadyExists(let url):
            return "Fotocopy will not overwrite \(url.path). Rename or move that existing file, then try again."
        case .duplicateDestination(let url):
            return "More than one marked file would be moved to \(url.path). Scan again before applying changes."
        }
    }
}

private struct CullApplyFileMove: Sendable {
    let sourceURL: URL
    let destinationURL: URL
}

enum CullApplyEngine {
    static func makePlan(
        folderURL: URL,
        dispositions: [URL: CullDisposition]
    ) throws -> CullApplyPlan {
        guard !dispositions.isEmpty else { throw CullApplyError.noMarkedFrames }

        let fm = FileManager.default
        let normalizedFolder = folderURL.standardizedFileURL
        let manifestRootURL = DestinationManifest.existingManifestRoot(containing: normalizedFolder)
        let orderedDispositions = dispositions.sorted {
            $0.key.path.localizedStandardCompare($1.key.path) == .orderedAscending
        }

        var fileMoves: [CullApplyFileMove] = []
        var relocations: [DestinationManifestRelocation] = []
        var seenDestinationPaths: Set<String> = []
        var selectCount = 0
        var rejectCount = 0
        var companionFileCount = 0

        for (sourceURL, disposition) in orderedDispositions {
            let normalizedSource = sourceURL.standardizedFileURL
            guard normalizedSource.deletingLastPathComponent() == normalizedFolder else {
                throw CullApplyError.sourceOutsideReviewFolder(normalizedSource)
            }
            guard fm.fileExists(atPath: normalizedSource.path) else {
                throw CullApplyError.sourceUnavailable(normalizedSource)
            }

            let destinationFolder = normalizedFolder
                .appendingPathComponent(disposition.destinationFolderName, isDirectory: true)
            let destinationURL = destinationFolder.appendingPathComponent(normalizedSource.lastPathComponent)
            try appendMove(
                from: normalizedSource,
                to: destinationURL,
                fileManager: fm,
                fileMoves: &fileMoves,
                seenDestinationPaths: &seenDestinationPaths
            )

            if let manifestRootURL {
                guard let previousRelativePath = relativePath(of: normalizedSource, within: manifestRootURL),
                      let currentRelativePath = relativePath(of: destinationURL, within: manifestRootURL) else {
                    throw CullApplyError.sourceOutsideReviewFolder(normalizedSource)
                }
                let size = try fileSize(of: normalizedSource, fileManager: fm)
                relocations.append(
                    DestinationManifestRelocation(
                        previousRelativePath: previousRelativePath,
                        currentRelativePath: currentRelativePath,
                        destinationSize: size
                    )
                )
            }

            for companionURL in companionURLs(for: normalizedSource, fileManager: fm) {
                let companionDestination = destinationFolder.appendingPathComponent(companionURL.lastPathComponent)
                try appendMove(
                    from: companionURL,
                    to: companionDestination,
                    fileManager: fm,
                    fileMoves: &fileMoves,
                    seenDestinationPaths: &seenDestinationPaths
                )
                companionFileCount += 1
            }

            switch disposition {
            case .select: selectCount += 1
            case .reject: rejectCount += 1
            }
        }

        if let manifestRootURL {
            try DestinationManifest(destinationURL: manifestRootURL).validateRelocations(relocations)
        }

        return CullApplyPlan(
            folderURL: normalizedFolder,
            selectCount: selectCount,
            rejectCount: rejectCount,
            companionFileCount: companionFileCount,
            fileMoves: fileMoves,
            manifestRootURL: manifestRootURL,
            manifestRelocations: relocations
        )
    }

    static func apply(_ plan: CullApplyPlan) throws -> CullApplyResult {
        let fm = FileManager.default
        for move in plan.fileMoves {
            try fm.createDirectory(
                at: move.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var completedMoves: [CullApplyFileMove] = []
        do {
            for move in plan.fileMoves {
                try fm.moveItem(at: move.sourceURL, to: move.destinationURL)
                completedMoves.append(move)
            }

            if let manifestRootURL = plan.manifestRootURL {
                try DestinationManifest(destinationURL: manifestRootURL)
                    .recordRelocations(plan.manifestRelocations)
            }
        } catch {
            rollback(completedMoves, fileManager: fm)
            throw error
        }

        return CullApplyResult(
            selectCount: plan.selectCount,
            rejectCount: plan.rejectCount,
            companionFileCount: plan.companionFileCount
        )
    }

    private static func appendMove(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        fileMoves: inout [CullApplyFileMove],
        seenDestinationPaths: inout Set<String>
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CullApplyError.sourceUnavailable(sourceURL)
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw CullApplyError.destinationAlreadyExists(destinationURL)
        }
        guard seenDestinationPaths.insert(destinationURL.standardizedFileURL.path).inserted else {
            throw CullApplyError.duplicateDestination(destinationURL)
        }
        fileMoves.append(
            CullApplyFileMove(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )
    }

    private static func companionURLs(for rawURL: URL, fileManager: FileManager) -> [URL] {
        let baseURL = rawURL.deletingPathExtension()
        let candidates = [
            rawURL.appendingPathExtension("xmp"),
            rawURL.appendingPathExtension("on1"),
            baseURL.appendingPathExtension("xmp"),
            baseURL.appendingPathExtension("on1")
        ]

        var seen: Set<String> = []
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted && fileManager.fileExists(atPath: $0.path)
        }
    }

    private static func relativePath(of fileURL: URL, within rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private static func fileSize(of url: URL, fileManager: FileManager) throws -> Int {
        guard let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw CullApplyError.sourceUnavailable(url)
        }
        return size.intValue
    }

    private static func rollback(_ moves: [CullApplyFileMove], fileManager: FileManager) {
        for move in moves.reversed() {
            guard fileManager.fileExists(atPath: move.destinationURL.path),
                  !fileManager.fileExists(atPath: move.sourceURL.path) else {
                continue
            }
            try? fileManager.moveItem(at: move.destinationURL, to: move.sourceURL)
        }
    }
}
