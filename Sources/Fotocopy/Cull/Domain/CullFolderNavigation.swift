import Foundation

/// The immediately adjacent cull folders around the current date folder.
/// Endpoints are `nil` deliberately: folder navigation must never wrap a
/// photographer from the oldest day to the newest (or vice versa).
struct CullFolderNeighbors: Sendable {
    let previous: URL?
    let next: URL?
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
        let root = libraryRoot.standardizedFileURL
        guard isSafeDirectory(root, fileManager: fileManager) else { return [] }

        var folders: [URL] = []
        for yearURL in childDirectories(of: root, fileManager: fileManager) where isYear(yearURL.lastPathComponent) {
            for monthURL in childDirectories(of: yearURL, fileManager: fileManager) where isMonth(monthURL.lastPathComponent) {
                for dayURL in childDirectories(of: monthURL, fileManager: fileManager) where isDay(
                    dayURL.lastPathComponent,
                    year: yearURL.lastPathComponent,
                    month: monthURL.lastPathComponent
                ) {
                    if containsReviewableCR3(in: dayURL, fileManager: fileManager) {
                        folders.append(dayURL.standardizedFileURL)
                    }
                }
            }
        }

        return folders.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func containsReviewableCR3(in folder: URL, fileManager: FileManager) -> Bool {
        if containsDirectCR3(in: folder, fileManager: fileManager) {
            return true
        }

        return CullDisposition.allCases.contains { disposition in
            let decisionFolder = folder.appendingPathComponent(
                disposition.destinationFolderName,
                isDirectory: true
            )
            return containsDirectCR3(in: decisionFolder, fileManager: fileManager)
        }
    }

    private static func containsDirectCR3(in directory: URL, fileManager: FileManager) -> Bool {
        guard isSafeDirectory(directory, fileManager: fileManager),
              let children = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return false
        }

        return children.contains { url in
            guard url.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
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
