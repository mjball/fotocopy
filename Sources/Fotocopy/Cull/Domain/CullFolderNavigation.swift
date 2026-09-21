import Foundation

/// The immediately adjacent cull folders around the current date folder.
/// Endpoints are `nil` deliberately: folder navigation must never wrap a
/// photographer from the oldest day to the newest (or vice versa).
struct CullFolderNeighbors: Sendable {
    let previous: URL?
    let next: URL?
}

/// A lightweight, filesystem-derived summary of one reviewable date folder.
/// Counts come only from directory entries; building the folder queue never
/// opens a RAW, reads capture metadata, or creates previews.
struct CullFolderReviewSummary: Identifiable, Sendable, Equatable {
    let folderURL: URL
    var unreviewedCount: Int
    var keptCount: Int
    var rejectedCount: Int
    var inventorySignature: String

    init(
        folderURL: URL,
        unreviewedCount: Int,
        keptCount: Int,
        rejectedCount: Int,
        inventorySignature: String = ""
    ) {
        self.folderURL = folderURL
        self.unreviewedCount = unreviewedCount
        self.keptCount = keptCount
        self.rejectedCount = rejectedCount
        self.inventorySignature = inventorySignature
    }

    var id: URL { folderURL }
    var totalCount: Int { unreviewedCount + keptCount + rejectedCount }
    var isReviewed: Bool { unreviewedCount == 0 }

    var dateLabel: String {
        let monthURL = folderURL.deletingLastPathComponent()
        let year = monthURL.deletingLastPathComponent().lastPathComponent
        return "\(year)/\(monthURL.lastPathComponent)/\(folderURL.lastPathComponent)"
    }

    func applying(_ relocations: [CullFrameRelocation]) -> CullFolderReviewSummary {
        var updated = self
        for relocation in relocations {
            guard let sourceBucket = Self.bucket(for: relocation.sourceURL, in: folderURL),
                  let destinationBucket = Self.bucket(for: relocation.destinationURL, in: folderURL),
                  sourceBucket != destinationBucket,
                  updated.count(for: sourceBucket) > 0 else {
                continue
            }
            updated.adjust(sourceBucket, by: -1)
            updated.adjust(destinationBucket, by: 1)
        }
        return updated
    }

    private enum Bucket {
        case unreviewed
        case kept
        case rejected
    }

    private static func bucket(for fileURL: URL, in folderURL: URL) -> Bucket? {
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        let folder = folderURL.standardizedFileURL
        if parent == folder { return .unreviewed }
        guard parent.deletingLastPathComponent().standardizedFileURL == folder else { return nil }
        switch parent.lastPathComponent {
        case CullDisposition.select.destinationFolderName: return .kept
        case CullDisposition.reject.destinationFolderName: return .rejected
        default: return nil
        }
    }

    private func count(for bucket: Bucket) -> Int {
        switch bucket {
        case .unreviewed: return unreviewedCount
        case .kept: return keptCount
        case .rejected: return rejectedCount
        }
    }

    private mutating func adjust(_ bucket: Bucket, by amount: Int) {
        switch bucket {
        case .unreviewed: unreviewedCount += amount
        case .kept: keptCount += amount
        case .rejected: rejectedCount += amount
        }
    }
}

struct CullFolderReviewSnapshot: Sendable, Equatable {
    let libraryRootURL: URL
    var folders: [CullFolderReviewSummary]

    var foldersNeedingReview: [CullFolderReviewSummary] {
        folders.reversed().filter { !$0.isReviewed }
    }

    var reviewedFolders: [CullFolderReviewSummary] {
        folders.reversed().filter(\.isReviewed)
    }

    mutating func replace(_ summary: CullFolderReviewSummary) {
        guard CullFolderNavigation.libraryRoot(containing: summary.folderURL) == libraryRootURL else { return }
        if let index = folders.firstIndex(where: { $0.folderURL == summary.folderURL }) {
            if summary.totalCount == 0 {
                folders.remove(at: index)
            } else {
                folders[index] = summary
            }
        } else if summary.totalCount > 0 {
            folders.append(summary)
            folders.sort { $0.folderURL.path.localizedStandardCompare($1.folderURL.path) == .orderedAscending }
        }
    }

    mutating func apply(_ relocations: [CullFrameRelocation], in folderURL: URL) {
        guard let index = folders.firstIndex(where: { $0.folderURL == folderURL.standardizedFileURL }) else { return }
        folders[index] = folders[index].applying(relocations)
    }

    mutating func removeTrashedRejects(_ rejectedURLs: [URL]) {
        let countsByFolder = Dictionary(grouping: rejectedURLs.compactMap { rejectedURL -> URL? in
            let rejectsFolder = rejectedURL.deletingLastPathComponent().standardizedFileURL
            guard rejectsFolder.lastPathComponent == CullDisposition.reject.destinationFolderName else { return nil }
            return rejectsFolder.deletingLastPathComponent().standardizedFileURL
        }, by: { $0 }).mapValues(\.count)

        for index in folders.indices.reversed() {
            let removedCount = countsByFolder[folders[index].folderURL] ?? 0
            guard removedCount > 0 else { continue }
            folders[index].rejectedCount = max(0, folders[index].rejectedCount - removedCount)
            if folders[index].totalCount == 0 {
                folders.remove(at: index)
            }
        }
    }
}

enum CullFolderNavigationError: LocalizedError {
    case libraryUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let url):
            return "The Cull library at \(url.path) is unavailable."
        }
    }
}

/// Finds Fotocopy's local `YYYY/MM/DD` folders without looking at photo
/// metadata. This keeps folder-to-folder navigation quick even on a slow
/// external drive, while limiting it to the same folders Cull can actually
/// review.
enum CullFolderNavigation {
    static func libraryRoot(containing folder: URL) -> URL? {
        let day = folder.standardizedFileURL
        let month = day.deletingLastPathComponent()
        let year = month.deletingLastPathComponent()

        guard isYear(year.lastPathComponent),
              isMonth(month.lastPathComponent),
              isDay(
                day.lastPathComponent,
                year: year.lastPathComponent,
                month: month.lastPathComponent
              ) else {
            return nil
        }

        return year.deletingLastPathComponent().standardizedFileURL
    }

    /// Returns chronological neighbors only when `folder` is itself a
    /// reviewable Fotocopy date folder under `libraryRoot`.
    static func neighbors(
        of folder: URL,
        in libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> CullFolderNeighbors? {
        let folders = cullFolders(in: libraryRoot, fileManager: fileManager)
        return neighbors(of: folder, among: folders)
    }

    static func neighbors(
        of folder: URL,
        among folders: [URL]
    ) -> CullFolderNeighbors? {
        let current = folder.standardizedFileURL
        guard let index = folders.firstIndex(where: { $0.standardizedFileURL == current }) else {
            return nil
        }

        return CullFolderNeighbors(
            previous: index > 0 ? folders[index - 1] : nil,
            next: index + 1 < folders.count ? folders[index + 1] : nil
        )
    }

    static func cullFolders(
        in libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        (try? reviewSummaries(in: libraryRoot, fileManager: fileManager).map(\.folderURL)) ?? []
    }

    static func reviewSummaries(
        in libraryRoot: URL,
        fileManager: FileManager = .default,
        cancellationCheck: () throws -> Void = {}
    ) throws -> [CullFolderReviewSummary] {
        let root = libraryRoot.standardizedFileURL
        guard isSafeDirectory(root, fileManager: fileManager) else {
            throw CullFolderNavigationError.libraryUnavailable(root)
        }

        var folders: [CullFolderReviewSummary] = []
        for yearURL in childDirectories(of: root, fileManager: fileManager) where isYear(yearURL.lastPathComponent) {
            try cancellationCheck()
            for monthURL in childDirectories(of: yearURL, fileManager: fileManager) where isMonth(monthURL.lastPathComponent) {
                try cancellationCheck()
                for dayURL in childDirectories(of: monthURL, fileManager: fileManager) where isDay(
                    dayURL.lastPathComponent,
                    year: yearURL.lastPathComponent,
                    month: monthURL.lastPathComponent
                ) {
                    try cancellationCheck()
                    let unreviewed = directCR3Inventory(
                        in: dayURL,
                        bucket: "unreviewed",
                        fileManager: fileManager
                    )
                    let kept = directCR3Inventory(
                        in: dayURL.appendingPathComponent(CullDisposition.select.destinationFolderName, isDirectory: true),
                        bucket: "kept",
                        fileManager: fileManager
                    )
                    let rejected = directCR3Inventory(
                        in: dayURL.appendingPathComponent(CullDisposition.reject.destinationFolderName, isDirectory: true),
                        bucket: "rejected",
                        fileManager: fileManager
                    )
                    guard unreviewed.count + kept.count + rejected.count > 0 else { continue }
                    folders.append(CullFolderReviewSummary(
                        folderURL: dayURL.standardizedFileURL,
                        unreviewedCount: unreviewed.count,
                        keptCount: kept.count,
                        rejectedCount: rejected.count,
                        inventorySignature: stableInventorySignature(
                            unreviewed.signatureParts + kept.signatureParts + rejected.signatureParts
                        )
                    ))
                }
            }
        }

        return folders.sorted {
            $0.folderURL.path.localizedStandardCompare($1.folderURL.path) == .orderedAscending
        }
    }

    private struct DirectCR3Inventory {
        let count: Int
        let signatureParts: [String]
    }

    private static func directCR3Inventory(
        in directory: URL,
        bucket: String,
        fileManager: FileManager
    ) -> DirectCR3Inventory {
        guard isSafeDirectory(directory, fileManager: fileManager),
              let children = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                  ],
                  options: [.skipsHiddenFiles]
              ) else {
            return DirectCR3Inventory(count: 0, signatureParts: [])
        }

        let signatureParts = children.compactMap { url -> String? in
            guard url.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame,
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            let size = values.fileSize ?? -1
            let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0
            return "\(bucket)|\(url.lastPathComponent)|\(size)|\(modified)"
        }
        .sorted()
        return DirectCR3Inventory(count: signatureParts.count, signatureParts: signatureParts)
    }

    /// A stable non-cryptographic digest is sufficient here: a collision can
    /// only make the disposable ranking cache stale, never authorize a move.
    private static func stableInventorySignature(_ parts: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in parts.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func childDirectories(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ))?.filter { isSafeDirectory($0, fileManager: fileManager) } ?? []
    }

    private static func isSafeDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
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
              let year = Int(year), let month = Int(month), let day = Int(value) else {
            return false
        }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }
}
