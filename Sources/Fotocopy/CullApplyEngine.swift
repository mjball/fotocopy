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

    static func inferred(from frameURL: URL, in folderURL: URL) -> CullDisposition? {
        let parent = frameURL.deletingLastPathComponent().standardizedFileURL
        let normalizedFolder = folderURL.standardizedFileURL
        guard parent.deletingLastPathComponent().standardizedFileURL == normalizedFolder else {
            return nil
        }
        return allCases.first { $0.destinationFolderName == parent.lastPathComponent }
    }
}

/// A reversible raw-file relocation inside the date folder being culled.
/// Its companion sidecars are derived and moved alongside the raw file.
struct CullFrameRelocation: Sendable, Equatable, Hashable {
    let sourceURL: URL
    let destinationURL: URL
}

struct CullApplyPlan: Sendable {
    let folderURL: URL
    let selectCount: Int
    let rejectCount: Int
    let companionFileCount: Int

    fileprivate let fileMoves: [CullApplyFileMove]
    fileprivate let manifestRootURL: URL?
    fileprivate let manifestRelocations: [DestinationManifestRelocation]
    fileprivate let rawRelocations: [CullFrameRelocation]

    var markedFrameCount: Int { selectCount + rejectCount }
}

struct CullApplyResult: Sendable, Equatable {
    let selectCount: Int
    let rejectCount: Int
    let companionFileCount: Int
    let rawRelocations: [CullFrameRelocation]

    var markedFrameCount: Int { selectCount + rejectCount }
}

enum CullApplyError: LocalizedError {
    case noMarkedFrames
    case noFileMoves
    case sourceOutsideReviewFolder(URL)
    case sourceUnavailable(URL)
    case destinationAlreadyExists(URL)
    case duplicateDestination(URL)

    var errorDescription: String? {
        switch self {
        case .noMarkedFrames:
            return "Mark at least one frame as a select or reject before applying changes."
        case .noFileMoves:
            return "No frame files need moving."
        case .sourceOutsideReviewFolder(let url):
            return "\(url.lastPathComponent) is no longer in this date folder. Scan again before moving it."
        case .sourceUnavailable(let url):
            return "\(url.lastPathComponent) is no longer available. Scan again before moving it."
        case .destinationAlreadyExists(let url):
            return "Fotocopy will not overwrite \(url.path). Rename or move that existing file, then try again."
        case .duplicateDestination(let url):
            return "More than one frame would be moved to \(url.path). Scan again before moving them."
        }
    }
}

private struct CullApplyFileMove: Sendable {
    let sourceURL: URL
    let destinationURL: URL
}

/// Performs reversible, physical cull moves. It is used both for an immediate
/// Keep/Reject action and for moving a marked frame back to the date folder.
enum CullApplyEngine {
    /// Compatibility entry point for batch decisions. Explicit marks move from
    /// the date folder into Selects or Rejects; unmarked frames are untouched.
    static func makePlan(
        folderURL: URL,
        dispositions: [URL: CullDisposition]
    ) throws -> CullApplyPlan {
        guard !dispositions.isEmpty else { throw CullApplyError.noMarkedFrames }

        let normalizedFolder = folderURL.standardizedFileURL
        let relocations = dispositions.map { sourceURL, disposition in
            CullFrameRelocation(
                sourceURL: sourceURL,
                destinationURL: normalizedFolder
                    .appendingPathComponent(disposition.destinationFolderName, isDirectory: true)
                    .appendingPathComponent(sourceURL.lastPathComponent)
            )
        }
        let selectCount = dispositions.values.filter { $0 == .select }.count
        let rejectCount = dispositions.values.filter { $0 == .reject }.count
        return try makePlan(
            folderURL: normalizedFolder,
            rawRelocations: relocations,
            selectCount: selectCount,
            rejectCount: rejectCount
        )
    }

    /// Builds a plan for an arbitrary reversible move between the date folder,
    /// Selects, and Rejects. A caller can use inverse relocations to undo the
    /// most recent cull action without deleting or rewriting image data.
    static func makePlan(
        folderURL: URL,
        rawRelocations: [CullFrameRelocation]
    ) throws -> CullApplyPlan {
        try makePlan(
            folderURL: folderURL.standardizedFileURL,
            rawRelocations: rawRelocations,
            selectCount: 0,
            rejectCount: 0
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
            companionFileCount: plan.companionFileCount,
            rawRelocations: plan.rawRelocations
        )
    }

    private static func makePlan(
        folderURL: URL,
        rawRelocations requestedRelocations: [CullFrameRelocation],
        selectCount: Int,
        rejectCount: Int
    ) throws -> CullApplyPlan {
        guard !requestedRelocations.isEmpty else { throw CullApplyError.noFileMoves }

        let fm = FileManager.default
        let normalizedFolder = folderURL.standardizedFileURL
        let manifestRootURL = DestinationManifest.existingManifestRoot(containing: normalizedFolder)
        let orderedRelocations = requestedRelocations.sorted {
            $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending
        }

        var fileMoves: [CullApplyFileMove] = []
        var manifestRelocations: [DestinationManifestRelocation] = []
        var normalizedRawRelocations: [CullFrameRelocation] = []
        var seenDestinationPaths: Set<String> = []
        var companionFileCount = 0

        for relocation in orderedRelocations {
            let sourceURL = relocation.sourceURL.standardizedFileURL
            let destinationURL = relocation.destinationURL.standardizedFileURL
            guard sourceURL != destinationURL else { continue }
            guard isReviewFrameURL(sourceURL, within: normalizedFolder),
                  isReviewFrameURL(destinationURL, within: normalizedFolder) else {
                throw CullApplyError.sourceOutsideReviewFolder(sourceURL)
            }
            guard fm.fileExists(atPath: sourceURL.path) else {
                throw CullApplyError.sourceUnavailable(sourceURL)
            }

            try appendMove(
                from: sourceURL,
                to: destinationURL,
                fileManager: fm,
                fileMoves: &fileMoves,
                seenDestinationPaths: &seenDestinationPaths
            )
            normalizedRawRelocations.append(
                CullFrameRelocation(sourceURL: sourceURL, destinationURL: destinationURL)
            )

            if let manifestRootURL {
                guard let previousRelativePath = relativePath(of: sourceURL, within: manifestRootURL),
                      let currentRelativePath = relativePath(of: destinationURL, within: manifestRootURL) else {
                    throw CullApplyError.sourceOutsideReviewFolder(sourceURL)
                }
                let size = try fileSize(of: sourceURL, fileManager: fm)
                manifestRelocations.append(
                    DestinationManifestRelocation(
                        previousRelativePath: previousRelativePath,
                        currentRelativePath: currentRelativePath,
                        destinationSize: size
                    )
                )
            }

            let destinationFolder = destinationURL.deletingLastPathComponent()
            for companionURL in companionURLs(for: sourceURL, fileManager: fm) {
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
        }

        guard !normalizedRawRelocations.isEmpty else { throw CullApplyError.noFileMoves }

        if let manifestRootURL {
            try DestinationManifest(destinationURL: manifestRootURL).validateRelocations(manifestRelocations)
        }

        return CullApplyPlan(
            folderURL: normalizedFolder,
            selectCount: selectCount,
            rejectCount: rejectCount,
            companionFileCount: companionFileCount,
            fileMoves: fileMoves,
            manifestRootURL: manifestRootURL,
            manifestRelocations: manifestRelocations,
            rawRelocations: normalizedRawRelocations
        )
    }

    private static func isReviewFrameURL(_ fileURL: URL, within folderURL: URL) -> Bool {
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        if parent == folderURL { return true }
        return parent.deletingLastPathComponent().standardizedFileURL == folderURL
            && [CullDisposition.select.destinationFolderName, CullDisposition.reject.destinationFolderName]
                .contains(parent.lastPathComponent)
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

    /// The one place where Fotocopy defines sidecars belonging to a raw photo.
    /// Both in-folder decisions and library-wide review use this so a Keep,
    /// Reject, or Trash action always carries the same package of files.
    static func companionURLs(for rawURL: URL, fileManager: FileManager = .default) -> [URL] {
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
