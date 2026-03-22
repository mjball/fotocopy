import Foundation
import AppKit

@Observable
@MainActor
final class ImportViewModel {
    var sourcePath = ""
    var destinationPath = ""
    var transferMode = TransferMode.copy.rawValue
    var excludedExtensionsRaw = ""
    var excludedCameraModelsRaw = ""

    var previewResult: PreviewResult?
    var isPreviewing = false
    var scanScanned = 0
    var scanTotal = 0
    var previewError: String?
    var dateFrom: Date?
    var dateTo: Date?
    var showDateFilter = false

    let progress = ImportProgress()
    private var importTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var sourceScanCache: SourceScanCache?

    var excludedExtensions: Set<String> {
        Set(excludedExtensionsRaw.split(separator: ",").map { String($0) })
    }

    var excludedCameraModels: Set<String> {
        Set(excludedCameraModelsRaw.split(separator: ",").map { String($0) })
    }

    var isPhotosLibrarySource: Bool {
        guard !sourcePath.isEmpty else { return false }
        return PhotosLibraryResolver.findPhotosLibraryRoot(from: URL(fileURLWithPath: sourcePath)) != nil
    }

    var activeFilter: ImportFilter {
        ImportFilter(
            excludedExtensions: excludedExtensions,
            excludedCameraModels: excludedCameraModels,
            dateFrom: dateFrom,
            dateTo: dateTo
        )
    }

    var filteredCounts: (total: Int, new: Int, duplicates: Int) {
        previewResult?.filteredCounts(by: activeFilter) ?? (0, 0, 0)
    }

    var importDisabledReason: String? {
        if sourcePath.isEmpty || destinationPath.isEmpty {
            return "Select source and destination folders"
        }
        if isPreviewing {
            return "Scanning in progress..."
        }
        if progress.isImporting {
            return nil
        }
        if let previewResult, previewResult.files.isEmpty {
            return "No supported files found in source"
        }
        if previewResult != nil, filteredCounts.new == 0 {
            return "No new files match current filters"
        }
        if previewResult == nil {
            return "Waiting for scan"
        }
        return nil
    }

    var isImportDisabled: Bool {
        importDisabledReason != nil
    }

    func toggleExtension(_ ext: String) {
        var set = excludedExtensions
        if set.contains(ext) {
            set.remove(ext)
        } else {
            set.insert(ext)
        }
        excludedExtensionsRaw = set.sorted().joined(separator: ",")
    }

    func toggleCameraModel(_ model: String) {
        var set = excludedCameraModels
        if set.contains(model) {
            set.remove(model)
        } else {
            set.insert(model)
        }
        excludedCameraModelsRaw = set.sorted().joined(separator: ",")
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        previewResult = nil
        previewError = nil
        scanScanned = 0
        scanTotal = 0
    }

    func invalidateSourceCache() {
        sourceScanCache = nil
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        progress.isImporting = false
    }

    func runPreview() {
        cancelPreview()

        guard !sourcePath.isEmpty, !destinationPath.isEmpty else { return }
        guard !progress.isImporting, !progress.isComplete else { return }

        isPreviewing = true
        scanScanned = 0
        scanTotal = 0
        previewError = nil
        let src = URL(fileURLWithPath: sourcePath)
        let dst = URL(fileURLWithPath: destinationPath)
        let cachedSource = sourceScanCache

        previewTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()

            do {
                try await checker.buildIndex(at: dst)

                let sourceFiles: [SourceFile]

                if let cachedSource, cachedSource.matches(path: sourcePath) {
                    sourceFiles = cachedSource.files
                } else {
                    let resolver = PhotosLibraryResolver.resolve(for: src)
                    sourceFiles = try await engine.scanSource(
                        source: src, resolver: resolver,
                        onProgress: { [weak self] scanned, total in
                            Task { @MainActor in
                                self?.scanScanned = scanned
                                self?.scanTotal = total
                            }
                        }
                    )
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.sourceScanCache = SourceScanCache(
                                sourcePath: self.sourcePath,
                                files: sourceFiles,
                                timestamp: Date()
                            )
                        }
                    }
                }

                let preview = await engine.checkDuplicates(
                    sourceFiles: sourceFiles, duplicateChecker: checker
                )
                if !Task.isCancelled {
                    previewResult = preview
                }
            } catch {
                if !Task.isCancelled {
                    previewError = error.localizedDescription
                }
            }

            isPreviewing = false
            scanScanned = 0
            scanTotal = 0
        }
    }

    func checkDiskSpace() -> String? {
        let dst = URL(fileURLWithPath: destinationPath)
        guard let preview = previewResult else { return nil }

        let filesToCopy = preview.filtered(by: activeFilter).filter { !$0.isDuplicate }
        let requiredBytes = filesToCopy.reduce(0) { $0 + $1.size }

        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dst.path),
              let freeBytes = attrs[.systemFreeSize] as? Int else { return nil }

        if requiredBytes > freeBytes {
            let needed = ByteCountFormatter.string(fromByteCount: Int64(requiredBytes), countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: Int64(freeBytes), countStyle: .file)
            return "Import needs \(needed) but only \(available) is available on the destination."
        }
        return nil
    }

    func startImport() {
        progress.reset()

        let dst = URL(fileURLWithPath: destinationPath)
        let mode = TransferMode(rawValue: transferMode) ?? .copy
        let filter = activeFilter
        let cachedPreview = previewResult

        previewTask?.cancel()
        previewResult = nil
        isPreviewing = false
        dateFrom = nil
        dateTo = nil
        showDateFilter = false

        importTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()

            do {
                try await checker.buildIndex(at: dst)

                let filesToImport: [PreviewFile]

                if let cachedPreview {
                    filesToImport = cachedPreview.filtered(by: filter)
                } else {
                    let src = URL(fileURLWithPath: sourcePath)
                    let resolver = PhotosLibraryResolver.resolve(for: src)
                    let (_, preview) = try await engine.previewImport(
                        source: src, duplicateChecker: checker, resolver: resolver
                    )
                    filesToImport = preview.filtered(by: filter)
                }

                progress.totalFiles = filesToImport.count
                progress.totalBytesToImport = filesToImport.reduce(0) { $0 + $1.size }
                progress.isImporting = true

                try await engine.importFiles(
                    files: filesToImport,
                    destination: dst,
                    mode: mode,
                    duplicateChecker: checker,
                    progress: progress
                )
            } catch {
                if !Task.isCancelled {
                    progress.errors.append((file: "Import", message: error.localizedDescription))
                }
            }

            progress.isImporting = false
            progress.isComplete = true
            importTask = nil
        }
    }

    func resetAndPreview() {
        progress.reset()
        runPreview()
    }

    func cleanup() {
        importTask?.cancel()
        previewTask?.cancel()
    }
}
