import Foundation

/// A filesystem-backed decision card. The raw CR3 is the identity; matching
/// XMP and ON1 files travel with it but are never presented as separate photos.
struct CullLibraryDecision: Identifiable, Sendable, Hashable {
    let rawURL: URL
    let disposition: CullDisposition
    let dateFolderURL: URL
    let dateLabel: String
    let companionURLs: [URL]
    let byteCount: Int

    var id: URL { rawURL }
    var filename: String { rawURL.lastPathComponent }
    var companionFileCount: Int { companionURLs.count }
}

struct CullLibraryDecisionScan: Sendable {
    let libraryRootURL: URL
    let decisions: [CullLibraryDecision]
    let imageStatistics: LibraryImageStatistics
    let scannedAt: Date

    var totalBytes: Int { decisions.reduce(0) { $0 + $1.byteCount } }
    var keptCount: Int { decisions.count { $0.disposition == .select } }
    var rejectedCount: Int { decisions.count { $0.disposition == .reject } }
}

/// The whole-library state behind the progress summaries. It deliberately
/// counts only primary still-image files: decision sidecars are operational
/// companions, not photographs, and video files are outside Cull's scope.
enum LibraryImageReviewState: CaseIterable, Sendable, Hashable {
    case unrated
    case kept
    case rejected

    var title: String {
        switch self {
        case .unrated: return "Unrated"
        case .kept: return "Kept"
        case .rejected: return "Rejected"
        }
    }
}

struct LibraryImageStatisticsBucket: Sendable, Equatable {
    let imageCount: Int
    let byteCount: Int

    static let empty = Self(imageCount: 0, byteCount: 0)
}

struct LibraryImageStatistics: Sendable, Equatable {
    let libraryRootURL: URL
    let unrated: LibraryImageStatisticsBucket
    let kept: LibraryImageStatisticsBucket
    let rejected: LibraryImageStatisticsBucket
    let scannedAt: Date

    var totalImageCount: Int { unrated.imageCount + kept.imageCount + rejected.imageCount }
    var totalByteCount: Int { unrated.byteCount + kept.byteCount + rejected.byteCount }

    func percentage(for state: LibraryImageReviewState) -> Int {
        guard totalImageCount > 0 else { return 0 }
        return Int((Double(bucket(for: state).imageCount) / Double(totalImageCount) * 100).rounded())
    }

    func bucket(for state: LibraryImageReviewState) -> LibraryImageStatisticsBucket {
        switch state {
        case .unrated: return unrated
        case .kept: return kept
        case .rejected: return rejected
        }
    }

    /// Cull moves preserve a primary image's bytes, so a successful move can
    /// update the visible buckets immediately instead of rereading the entire
    /// external library after every Keep, Reject, or Undo.
    func applying(
        rawRelocations: [CullFrameRelocation],
        rawFileByteCounts: [URL: Int],
        in dateFolderURL: URL
    ) -> Self? {
        var buckets = Dictionary(uniqueKeysWithValues: LibraryImageReviewState.allCases.map {
            ($0, bucket(for: $0))
        })

        for relocation in rawRelocations {
            guard let sourceState = Self.reviewState(of: relocation.sourceURL, in: dateFolderURL),
                  let destinationState = Self.reviewState(of: relocation.destinationURL, in: dateFolderURL),
                  let byteCount = rawFileByteCounts[relocation.sourceURL.standardizedFileURL] else {
                return nil
            }
            guard sourceState != destinationState,
                  let sourceBucket = buckets[sourceState],
                  let destinationBucket = buckets[destinationState],
                  sourceBucket.imageCount > 0,
                  sourceBucket.byteCount >= byteCount else {
                return nil
            }
            buckets[sourceState] = LibraryImageStatisticsBucket(
                imageCount: sourceBucket.imageCount - 1,
                byteCount: sourceBucket.byteCount - byteCount
            )
            buckets[destinationState] = LibraryImageStatisticsBucket(
                imageCount: destinationBucket.imageCount + 1,
                byteCount: destinationBucket.byteCount + byteCount
            )
        }

        return Self(
            libraryRootURL: libraryRootURL,
            unrated: buckets[.unrated] ?? .empty,
            kept: buckets[.kept] ?? .empty,
            rejected: buckets[.rejected] ?? .empty,
            scannedAt: scannedAt
        )
    }

    private static func reviewState(of fileURL: URL, in dateFolderURL: URL) -> LibraryImageReviewState? {
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        let dateFolder = dateFolderURL.standardizedFileURL
        if parent == dateFolder { return .unrated }
        guard parent.deletingLastPathComponent().standardizedFileURL == dateFolder else { return nil }
        switch parent.lastPathComponent {
        case CullDisposition.select.destinationFolderName: return .kept
        case CullDisposition.reject.destinationFolderName: return .rejected
        default: return nil
        }
    }
}

enum CullLibraryDecisionFilter: String, CaseIterable, Identifiable {
    case all
    case kept
    case rejected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Decisions"
        case .kept: return "Kept"
        case .rejected: return "Rejected"
        }
    }

    func includes(_ decision: CullLibraryDecision) -> Bool {
        switch self {
        case .all: return true
        case .kept: return decision.disposition == .select
        case .rejected: return decision.disposition == .reject
        }
    }
}

struct CullLibraryTrashPlan: Identifiable, Sendable {
    let id = UUID()
    let libraryRootURL: URL
    let packages: [CullLibraryDecision]
    let createdAt: Date

    var primaryPhotoCount: Int { packages.count }
    var companionFileCount: Int { packages.reduce(0) { $0 + $1.companionFileCount } }
    var totalBytes: Int { packages.reduce(0) { $0 + $1.byteCount } }
    var affectedDateLabels: [String] { Array(Set(packages.map(\.dateLabel))).sorted() }
}

struct CullLibraryTrashFailure: Identifiable, Sendable, Hashable {
    let rawURL: URL
    let message: String

    var id: URL { rawURL }
}

struct CullLibraryTrashResult: Sendable {
    let trashedPrimaryPhotoURLs: [URL]
    let trashedCompanionFileCount: Int
    let failures: [CullLibraryTrashFailure]
    let manifestError: String?

    var trashedPrimaryPhotoCount: Int { trashedPrimaryPhotoURLs.count }
}

enum CullLibraryDecisionError: LocalizedError {
    case libraryUnavailable(URL)
    case noRejectedPhotos
    case staleOrUnsafeDecision(URL)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let url):
            return "The Fotocopy library at \(url.path) is unavailable."
        case .noRejectedPhotos:
            return "There are no rejected photos to move to Trash."
        case .staleOrUnsafeDecision(let url):
            return "\(url.lastPathComponent) is no longer a direct file in this library's Rejects folder. Refresh Library Decisions before trying again."
        }
    }
}

/// Discovers Fotocopy's YYYY/MM/DD image hierarchy without following symlinks
/// or treating arbitrary folders as library photos or cull decisions.
enum LibraryDecisionEngine {
    /// The still-image types Fotocopy imports and can report in library
    /// progress. Videos remain importable but are intentionally excluded from
    /// culling statistics.
    static let supportedStillImageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif",
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"
    ]

    /// Import may be pointed at a volume while the existing Fotocopy library
    /// lives in its conventional `Fotocopy` child. Prefer the selected folder
    /// when it already looks like a library; otherwise adopt that child only
    /// when it contains Fotocopy's date hierarchy or manifest.
    static func libraryRoot(forImportDestination importDestinationURL: URL, fileManager: FileManager = .default) -> URL {
        let destination = importDestinationURL.standardizedFileURL
        guard isSafeDirectory(destination, fileManager: fileManager) else { return destination }
        if looksLikeLibraryRoot(destination, fileManager: fileManager) { return destination }

        let conventionalChild = destination.appendingPathComponent("Fotocopy", isDirectory: true)
        if looksLikeLibraryRoot(conventionalChild, fileManager: fileManager) {
            return conventionalChild.standardizedFileURL
        }
        return destination
    }

    static func scan(libraryRootURL: URL, fileManager: FileManager = .default) throws -> CullLibraryDecisionScan {
        let root = libraryRootURL.standardizedFileURL
        guard isSafeDirectory(root, fileManager: fileManager) else {
            throw CullLibraryDecisionError.libraryUnavailable(root)
        }

        var decisions: [CullLibraryDecision] = []
        var imageBuckets = Dictionary(uniqueKeysWithValues: LibraryImageReviewState.allCases.map {
            ($0, LibraryImageStatisticsBucket.empty)
        })
        for yearURL in childDirectories(of: root, fileManager: fileManager) where isYear(yearURL.lastPathComponent) {
            for monthURL in childDirectories(of: yearURL, fileManager: fileManager) where isMonth(monthURL.lastPathComponent) {
                for dayURL in childDirectories(of: monthURL, fileManager: fileManager) where isDay(dayURL.lastPathComponent, year: yearURL.lastPathComponent, month: monthURL.lastPathComponent) {
                    let dateLabel = "\(yearURL.lastPathComponent)/\(monthURL.lastPathComponent)/\(dayURL.lastPathComponent)"
                    addImageFiles(
                        directImageFiles(in: dayURL, fileManager: fileManager),
                        to: .unrated,
                        buckets: &imageBuckets,
                        fileManager: fileManager
                    )
                    for disposition in CullDisposition.allCases {
                        let decisionFolder = dayURL.appendingPathComponent(disposition.destinationFolderName, isDirectory: true)
                        guard isSafeDirectory(decisionFolder, fileManager: fileManager) else { continue }

                        let imageFiles = directImageFiles(in: decisionFolder, fileManager: fileManager)
                        addImageFiles(
                            imageFiles,
                            to: disposition == .select ? .kept : .rejected,
                            buckets: &imageBuckets,
                            fileManager: fileManager
                        )

                        for rawURL in imageFiles where rawURL.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame {
                            let companions = CullApplyEngine.companionURLs(for: rawURL, fileManager: fileManager)
                                .filter { isSafePlainFile($0, in: decisionFolder, fileManager: fileManager) }
                            let bytes = fileSize(rawURL, fileManager: fileManager)
                                + companions.reduce(0) { $0 + fileSize($1, fileManager: fileManager) }
                            decisions.append(CullLibraryDecision(
                                rawURL: rawURL,
                                disposition: disposition,
                                dateFolderURL: dayURL,
                                dateLabel: dateLabel,
                                companionURLs: companions,
                                byteCount: bytes
                            ))
                        }
                    }
                }
            }
        }

        decisions.sort {
            if $0.dateLabel != $1.dateLabel { return $0.dateLabel > $1.dateLabel }
            return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }
        let scannedAt = Date()
        return CullLibraryDecisionScan(
            libraryRootURL: root,
            decisions: decisions,
            imageStatistics: LibraryImageStatistics(
                libraryRootURL: root,
                unrated: imageBuckets[.unrated] ?? .empty,
                kept: imageBuckets[.kept] ?? .empty,
                rejected: imageBuckets[.rejected] ?? .empty,
                scannedAt: scannedAt
            ),
            scannedAt: scannedAt
        )
    }

    static func scanImageStatistics(libraryRootURL: URL, fileManager: FileManager = .default) throws -> LibraryImageStatistics {
        let root = libraryRootURL.standardizedFileURL
        guard isSafeDirectory(root, fileManager: fileManager) else {
            throw CullLibraryDecisionError.libraryUnavailable(root)
        }

        var buckets = Dictionary(uniqueKeysWithValues: LibraryImageReviewState.allCases.map {
            ($0, LibraryImageStatisticsBucket.empty)
        })
        for yearURL in childDirectories(of: root, fileManager: fileManager) where isYear(yearURL.lastPathComponent) {
            for monthURL in childDirectories(of: yearURL, fileManager: fileManager) where isMonth(monthURL.lastPathComponent) {
                for dayURL in childDirectories(of: monthURL, fileManager: fileManager) where isDay(dayURL.lastPathComponent, year: yearURL.lastPathComponent, month: monthURL.lastPathComponent) {
                    addImageFiles(
                        directImageFiles(in: dayURL, fileManager: fileManager),
                        to: .unrated,
                        buckets: &buckets,
                        fileManager: fileManager
                    )
                    for disposition in CullDisposition.allCases {
                        let decisionFolder = dayURL.appendingPathComponent(disposition.destinationFolderName, isDirectory: true)
                        guard isSafeDirectory(decisionFolder, fileManager: fileManager) else { continue }
                        addImageFiles(
                            directImageFiles(in: decisionFolder, fileManager: fileManager),
                            to: disposition == .select ? .kept : .rejected,
                            buckets: &buckets,
                            fileManager: fileManager
                        )
                    }
                }
            }
        }

        return LibraryImageStatistics(
            libraryRootURL: root,
            unrated: buckets[.unrated] ?? .empty,
            kept: buckets[.kept] ?? .empty,
            rejected: buckets[.rejected] ?? .empty,
            scannedAt: Date()
        )
    }

    static func makeTrashPlan(libraryRootURL: URL, fileManager: FileManager = .default) throws -> CullLibraryTrashPlan {
        let scan = try scan(libraryRootURL: libraryRootURL, fileManager: fileManager)
        return try makeTrashPlan(from: scan)
    }

    static func makeTrashPlan(from scan: CullLibraryDecisionScan) throws -> CullLibraryTrashPlan {
        let packages = scan.decisions.filter { $0.disposition == .reject }
        guard !packages.isEmpty else { throw CullLibraryDecisionError.noRejectedPhotos }
        return CullLibraryTrashPlan(libraryRootURL: scan.libraryRootURL, packages: packages, createdAt: Date())
    }

    /// Uses FileManager's native macOS Trash operation. There is deliberately
    /// no removeItem fallback: a failed native Trash move remains a failure.
    static func executeTrash(_ plan: CullLibraryTrashPlan) -> CullLibraryTrashResult {
        executeTrash(
            plan,
            trashItem: { url in
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            },
            recordDeletedPaths: { root, paths in
                try DestinationManifest(destinationURL: root).recordDeletedPaths(paths)
            }
        )
    }

    /// Dependency-injected seam for deterministic tests of stale files,
    /// partial trash failures, and a manifest write that fails after a move.
    static func executeTrash(
        _ plan: CullLibraryTrashPlan,
        trashItem: (URL) throws -> Void,
        recordDeletedPaths: (URL, [String]) throws -> Void
    ) -> CullLibraryTrashResult {
        var trashedPrimaryPhotoURLs: [URL] = []
        var trashedCompanionFileCount = 0
        var failures: [CullLibraryTrashFailure] = []
        var deletedRelativePaths: [String] = []

        for package in plan.packages {
            do {
                let files = try revalidatedPackageFiles(package, libraryRootURL: plan.libraryRootURL)
                try trashItem(files[0])
                trashedPrimaryPhotoURLs.append(package.rawURL)
                if let relativePath = relativePath(of: package.rawURL, within: plan.libraryRootURL) {
                    deletedRelativePaths.append(relativePath)
                }
                for companionURL in files.dropFirst() {
                    do {
                        try trashItem(companionURL)
                        trashedCompanionFileCount += 1
                    } catch {
                        failures.append(CullLibraryTrashFailure(rawURL: package.rawURL, message: "\(package.filename): the photo was sent to Trash, but \(companionURL.lastPathComponent) could not be moved: \(error.localizedDescription)"))
                    }
                }
            } catch {
                failures.append(CullLibraryTrashFailure(rawURL: package.rawURL, message: error.localizedDescription))
            }
        }

        let manifestError: String?
        do {
            try recordDeletedPaths(plan.libraryRootURL, deletedRelativePaths)
            manifestError = nil
        } catch {
            manifestError = "The photo files were sent to Finder's Trash, but Fotocopy could not update its duplicate-history manifest: \(error.localizedDescription)"
        }
        return CullLibraryTrashResult(
            trashedPrimaryPhotoURLs: trashedPrimaryPhotoURLs,
            trashedCompanionFileCount: trashedCompanionFileCount,
            failures: failures,
            manifestError: manifestError
        )
    }

    private static func revalidatedPackageFiles(_ package: CullLibraryDecision, libraryRootURL: URL) throws -> [URL] {
        let root = libraryRootURL.standardizedFileURL
        let rawURL = package.rawURL.standardizedFileURL
        let rejectFolder = package.dateFolderURL
            .standardizedFileURL
            .appendingPathComponent(CullDisposition.reject.destinationFolderName, isDirectory: true)
        guard package.disposition == .reject,
              isRecognizedDateFolder(package.dateFolderURL, beneath: root),
              rawURL.deletingLastPathComponent().standardizedFileURL == rejectFolder,
              isSafePlainFile(rawURL, in: rejectFolder, fileManager: .default) else {
            throw CullLibraryDecisionError.staleOrUnsafeDecision(rawURL)
        }

        let currentCompanions = CullApplyEngine.companionURLs(for: rawURL)
            .filter { isSafePlainFile($0, in: rejectFolder, fileManager: .default) }
        let plannedPaths = Set(package.companionURLs.map { $0.standardizedFileURL.path })
        let currentPaths = Set(currentCompanions.map { $0.standardizedFileURL.path })
        guard plannedPaths == currentPaths else {
            throw CullLibraryDecisionError.staleOrUnsafeDecision(rawURL)
        }
        return [rawURL] + currentCompanions
    }

    private static func childDirectories(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ))?.filter { isSafeDirectory($0, fileManager: fileManager) } ?? []
    }

    private static func looksLikeLibraryRoot(_ url: URL, fileManager: FileManager) -> Bool {
        guard isSafeDirectory(url, fileManager: fileManager) else { return false }
        let manifest = url
            .appendingPathComponent(DestinationManifest.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent(DestinationManifest.databaseFilename)
        if fileManager.fileExists(atPath: manifest.path) { return true }
        return childDirectories(of: url, fileManager: fileManager).contains { yearURL in
            guard isYear(yearURL.lastPathComponent) else { return false }
            return childDirectories(of: yearURL, fileManager: fileManager).contains { monthURL in
                guard isMonth(monthURL.lastPathComponent) else { return false }
                return childDirectories(of: monthURL, fileManager: fileManager).contains {
                    isDay($0.lastPathComponent, year: yearURL.lastPathComponent, month: monthURL.lastPathComponent)
                }
            }
        }
    }

    private static func directImageFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            supportedStillImageExtensions.contains(url.pathExtension.lowercased())
                && isSafePlainFile(url, in: directory, fileManager: fileManager)
        } ?? []
    }

    private static func addImageFiles(
        _ imageFiles: [URL],
        to state: LibraryImageReviewState,
        buckets: inout [LibraryImageReviewState: LibraryImageStatisticsBucket],
        fileManager: FileManager
    ) {
        guard let current = buckets[state] else { return }
        buckets[state] = LibraryImageStatisticsBucket(
            imageCount: current.imageCount + imageFiles.count,
            byteCount: current.byteCount + imageFiles.reduce(0) { $0 + fileSize($1, fileManager: fileManager) }
        )
    }

    private static func isSafeDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private static func isSafePlainFile(_ url: URL, in parent: URL, fileManager: FileManager) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
              !url.lastPathComponent.hasPrefix("."),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    static func isRecognizedDateFolder(_ dateFolder: URL, beneath root: URL) -> Bool {
        let day = dateFolder.standardizedFileURL
        let month = day.deletingLastPathComponent()
        let year = month.deletingLastPathComponent()
        return isSafeDirectory(root, fileManager: .default)
            && isSafeDirectory(year, fileManager: .default)
            && isSafeDirectory(month, fileManager: .default)
            && isSafeDirectory(day, fileManager: .default)
            && year.deletingLastPathComponent().standardizedFileURL == root
            && isYear(year.lastPathComponent)
            && isMonth(month.lastPathComponent)
            && isDay(day.lastPathComponent, year: year.lastPathComponent, month: month.lastPathComponent)
    }

    private static func isYear(_ value: String) -> Bool {
        value.count == 4 && value.allSatisfy(\.isNumber)
    }

    private static func isMonth(_ value: String) -> Bool {
        guard value.count == 2, let month = Int(value) else { return false }
        return (1...12).contains(month)
    }

    private static func isDay(_ value: String, year: String, month: String) -> Bool {
        guard value.count == 2,
              let year = Int(year), let month = Int(month), let day = Int(value) else { return false }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func relativePath(of url: URL, within root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
