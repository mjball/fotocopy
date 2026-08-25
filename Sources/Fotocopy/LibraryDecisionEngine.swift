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
    let scannedAt: Date

    var totalBytes: Int { decisions.reduce(0) { $0 + $1.byteCount } }
    var keptCount: Int { decisions.count { $0.disposition == .select } }
    var rejectedCount: Int { decisions.count { $0.disposition == .reject } }
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

/// Discovers only Fotocopy's YYYY/MM/DD/{Keeps,Rejects} decision folders.
/// It never follows symlinks or treats arbitrary folders as cull decisions.
enum LibraryDecisionEngine {
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
        for yearURL in childDirectories(of: root, fileManager: fileManager) where isYear(yearURL.lastPathComponent) {
            for monthURL in childDirectories(of: yearURL, fileManager: fileManager) where isMonth(monthURL.lastPathComponent) {
                for dayURL in childDirectories(of: monthURL, fileManager: fileManager) where isDay(dayURL.lastPathComponent, year: yearURL.lastPathComponent, month: monthURL.lastPathComponent) {
                    let dateLabel = "\(yearURL.lastPathComponent)/\(monthURL.lastPathComponent)/\(dayURL.lastPathComponent)"
                    for disposition in CullDisposition.allCases {
                        let decisionFolder = dayURL.appendingPathComponent(disposition.destinationFolderName, isDirectory: true)
                        guard isSafeDirectory(decisionFolder, fileManager: fileManager) else { continue }

                        for rawURL in directCR3Files(in: decisionFolder, fileManager: fileManager) {
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
        return CullLibraryDecisionScan(libraryRootURL: root, decisions: decisions, scannedAt: Date())
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

    private static func directCR3Files(in directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            url.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame
                && isSafePlainFile(url, in: directory, fileManager: fileManager)
        } ?? []
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

    private static func isRecognizedDateFolder(_ dateFolder: URL, beneath root: URL) -> Bool {
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
