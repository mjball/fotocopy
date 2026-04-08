import Foundation
import AVFoundation

struct SourceScanCache: Sendable {
    let sourcePath: String
    let files: [SourceFile]
    let timestamp: Date

    private static let maxAge: TimeInterval = 300 // 5 minutes

    var isValid: Bool {
        Date().timeIntervalSince(timestamp) < Self.maxAge
    }

    func matches(path: String) -> Bool {
        sourcePath == path && isValid
    }
}

struct SourceFile: Sendable {
    let url: URL
    let filename: String
    let sourceBucket: String
    let ext: String
    let size: Int
    let date: Date?
    let dateSource: DateSource?
    let cameraModel: String?
}

struct PreviewFile: Sendable {
    let url: URL
    let filename: String
    let sourceBucket: String
    let ext: String
    let size: Int
    let date: Date?
    let dateSource: DateSource?
    let cameraModel: String?
    let isDuplicate: Bool

    init(source: SourceFile, isDuplicate: Bool) {
        self.url = source.url
        self.filename = source.filename
        self.sourceBucket = source.sourceBucket
        self.ext = source.ext
        self.size = source.size
        self.date = source.date
        self.dateSource = source.dateSource
        self.cameraModel = source.cameraModel
        self.isDuplicate = isDuplicate
    }

    init(url: URL, filename: String, sourceBucket: String = DestinationManifest.rootBucket, ext: String, size: Int, date: Date?, dateSource: DateSource?, cameraModel: String?, isDuplicate: Bool) {
        self.url = url
        self.filename = filename
        self.sourceBucket = sourceBucket
        self.ext = ext
        self.size = size
        self.date = date
        self.dateSource = dateSource
        self.cameraModel = cameraModel
        self.isDuplicate = isDuplicate
    }
}

struct PreviewResult: Sendable {
    let files: [PreviewFile]

    var extensionCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for file in files {
            counts[file.ext, default: 0] += 1
        }
        return counts
    }

    var cameraModelCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for file in files {
            if let model = file.cameraModel {
                counts[model, default: 0] += 1
            }
        }
        return counts
    }

    var dateRange: (min: Date, max: Date)? {
        let dates = files.compactMap(\.date)
        guard let min = dates.min(), let max = dates.max() else { return nil }
        return (min, max)
    }

    func filtered(by filter: ImportFilter) -> [PreviewFile] {
        files.filter { filter.includes($0) }
    }

    func filteredCounts(by filter: ImportFilter) -> (total: Int, new: Int, duplicates: Int) {
        let matched = filtered(by: filter)
        let dupes = matched.filter(\.isDuplicate).count
        return (matched.count, matched.count - dupes, dupes)
    }
}

actor ImportEngine {
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif",
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2",
        "mov", "mp4", "m4v"
    ]

    private static let skippedDirectories: Set<String> = [
        "Cache", "Thumbnails", "resources", "Derivatives"
    ]

    func discoverFiles(in sourceURL: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey]
            ) else { continue }

            if resourceValues.isDirectory == true {
                if Self.skippedDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resourceValues.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                files.append(fileURL)
            }
        }
        return files
    }

    func scanSource(
        source: URL,
        resolver: PhotosLibraryResolver? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [SourceFile] {
        let urls = try discoverFiles(in: source)
        let fm = FileManager.default
        let total = urls.count
        let maxConcurrency = 16
        let sourceBuckets = Self.sourceBuckets(
            for: urls,
            sourceRoot: source,
            resolver: resolver
        )

        return await withTaskGroup(of: SourceFile?.self) { group in
            var results: [SourceFile] = []
            var running = 0
            var scanned = 0

            for fileURL in urls {
                if Task.isCancelled { break }

                if running >= maxConcurrency {
                    if let file = await group.next() ?? nil {
                        results.append(file)
                    }
                    running -= 1
                    scanned += 1
                    onProgress?(scanned, total)
                }

                group.addTask {
                    let rawFilename = fileURL.lastPathComponent
                    let filename = resolver?.originalFilename(for: rawFilename) ?? rawFilename
                    let sourceBucket = sourceBuckets[fileURL] ?? DestinationManifest.rootBucket
                    let ext = (filename as NSString).pathExtension.lowercased()

                    guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                          let fileSize = attrs[.size] as? Int else { return nil }

                    let metadata = await EXIFDateReader.readMetadata(from: fileURL)

                    return SourceFile(
                        url: fileURL,
                        filename: filename,
                        sourceBucket: sourceBucket,
                        ext: ext,
                        size: fileSize,
                        date: metadata.dateResult?.date,
                        dateSource: metadata.dateResult?.source,
                        cameraModel: metadata.cameraModel
                    )
                }
                running += 1
            }

            for await file in group {
                if let file {
                    results.append(file)
                }
                scanned += 1
                onProgress?(scanned, total)
            }

            return results
        }
    }

    func checkDuplicates(
        sourceFiles: [SourceFile],
        duplicateChecker: DuplicateChecker
    ) async -> PreviewResult {
        var previewFiles: [PreviewFile] = []
        for source in sourceFiles {
            let isDuplicate = await duplicateChecker.isDuplicate(
                filename: source.filename,
                size: source.size,
                sourceBucket: source.sourceBucket
            )
            previewFiles.append(PreviewFile(source: source, isDuplicate: isDuplicate))
        }
        return PreviewResult(files: previewFiles)
    }

    func previewImport(
        source: URL,
        duplicateChecker: DuplicateChecker,
        resolver: PhotosLibraryResolver? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (sourceFiles: [SourceFile], preview: PreviewResult) {
        let sourceFiles = try await scanSource(
            source: source, resolver: resolver, onProgress: onProgress
        )
        let preview = await checkDuplicates(
            sourceFiles: sourceFiles, duplicateChecker: duplicateChecker
        )
        return (sourceFiles, preview)
    }

    func importFiles(
        files: [PreviewFile],
        destination: URL,
        mode: TransferMode,
        duplicateChecker: DuplicateChecker,
        progress: ImportProgress
    ) async throws {
        let fm = FileManager.default
        let maxConcurrency = 8

        await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0

            for file in files {
                if Task.isCancelled { break }

                if file.isDuplicate {
                    await MainActor.run {
                        progress.recordDuplicateSkipped()
                    }
                    continue
                }

                if running >= maxConcurrency {
                    _ = try? await group.next()
                    running -= 1
                }

                group.addTask {
                    try await self.processFile(
                        file: file,
                        destination: destination,
                        mode: mode,
                        duplicateChecker: duplicateChecker,
                        progress: progress,
                        fileManager: fm
                    )
                }
                running += 1
            }
        }
    }

    private func processFile(
        file: PreviewFile,
        destination: URL,
        mode: TransferMode,
        duplicateChecker: DuplicateChecker,
        progress: ImportProgress,
        fileManager fm: FileManager
    ) async throws {
        let filename = file.filename

        await MainActor.run { progress.currentFile = filename }

        guard let date = file.date else {
            await MainActor.run {
                progress.errors.append((file: filename, message: "Could not determine date"))
                progress.recordFailedTransfer(bytes: file.size)
            }
            return
        }

        if file.dateSource == .filesystem {
            await MainActor.run {
                progress.fallbackDateFiles.append(filename)
            }
        }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)

        let destDir = destination
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent(day)
        let destFile = destDir.appendingPathComponent(filename)

        var didSucceed = false

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            var finalDest = destFile
            if fm.fileExists(atPath: finalDest.path) {
                let stem = (filename as NSString).deletingPathExtension
                let ext = (filename as NSString).pathExtension
                var counter = 1
                repeat {
                    finalDest = destDir.appendingPathComponent("\(stem)_\(counter).\(ext)")
                    counter += 1
                } while fm.fileExists(atPath: finalDest.path)
            }

            switch mode {
            case .copy:
                try fm.copyItem(at: file.url, to: finalDest)
            case .move:
                try fm.moveItem(at: file.url, to: finalDest)
            }

            let relativePath = self.relativePath(for: finalDest, within: destination)
            try await duplicateChecker.markImported(
                filename: filename,
                size: file.size,
                sourceBucket: file.sourceBucket,
                destinationRelativePath: relativePath,
                destinationSize: file.size
            )
            didSucceed = true
        } catch {
            await MainActor.run {
                progress.errors.append((file: filename, message: error.localizedDescription))
                progress.recordFailedTransfer(bytes: file.size)
            }
        }

        guard didSucceed else { return }

        await MainActor.run {
            progress.recordSuccessfulTransfer(bytes: file.size)
        }
    }

    private static func sourceBuckets(
        for fileURLs: [URL],
        sourceRoot: URL,
        resolver: PhotosLibraryResolver?
    ) -> [URL: String] {
        guard resolver == nil else {
            return Dictionary(
                uniqueKeysWithValues: fileURLs.map { ($0, DestinationManifest.photosLibraryBucket) }
            )
        }

        let identitiesByURL = Dictionary(
            uniqueKeysWithValues: fileURLs.map {
                ($0, sourceFolderIdentity(for: $0, sourceRoot: sourceRoot))
            }
        )
        let numberedIdentities = identitiesByURL.values
            .filter { $0 != DestinationManifest.rootBucket }
        let bucketIDsByIdentity = Dictionary(
            uniqueKeysWithValues: Array(Set(numberedIdentities))
                .sorted()
                .enumerated()
                .map { index, identity in
                    (identity, String(format: "%03d", 100 + index))
                }
        )

        return Dictionary(
            uniqueKeysWithValues: identitiesByURL.map { fileURL, identity in
                let bucket = bucketIDsByIdentity[identity] ?? DestinationManifest.rootBucket
                return (fileURL, bucket)
            }
        )
    }

    private static func sourceFolderIdentity(
        for fileURL: URL,
        sourceRoot: URL
    ) -> String {
        let rootPath = sourceRoot.standardizedFileURL.path
        let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
        let relativeParent: String
        if parentPath == rootPath {
            relativeParent = ""
        } else {
            relativeParent = String(parentPath.dropFirst(rootPath.count + 1))
        }

        let components = relativeParent.split(separator: "/")
        for index in components.indices.reversed() {
            let prefix = components[index].prefix(3)
            if prefix.count == 3, prefix.allSatisfy(\.isNumber) {
                return components[...index].joined(separator: "/")
            }
        }

        return relativeParent.isEmpty ? DestinationManifest.rootBucket : relativeParent
    }

    private func relativePath(for fileURL: URL, within rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}
