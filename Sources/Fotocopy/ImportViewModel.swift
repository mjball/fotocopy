import Foundation
import AppKit

struct PreviewRequest: Equatable {
    let generation: Int
    let sourcePath: String
    let destinationPath: String
}

enum SourcePathAvailability: Equatable {
    case available
    case volumeNotMounted(name: String)
    case folderUnavailable

    var message: String? {
        switch self {
        case .available:
            return nil
        case let .volumeNotMounted(name):
            return "Source volume \(name) is not mounted"
        case .folderUnavailable:
            return "Source folder is not available"
        }
    }
}

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
    var isRebuildingManifest = false
    var scanScanned = 0
    var scanTotal = 0
    var previewError: String?
    var manifestAttention: ManifestAttention?
    var sourceAvailability: SourcePathAvailability?
    var dateFrom: Date?
    var dateTo: Date?
    var showDateFilter = false

    let progress = ImportProgress()
    private var importTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var sourceScanCache: SourceScanCache?
    private(set) var previewGeneration = 0

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

    var importDateRange: (min: Date, max: Date)? {
        previewResult?.importDateRange(by: activeFilter)
    }

    var availableImportDateRange: (min: Date, max: Date)? {
        previewResult?.availableImportDateRange(by: activeFilter)
    }

    var importDisabledReason: String? {
        if sourcePath.isEmpty || destinationPath.isEmpty {
            return "Select source and destination folders"
        }
        if let sourceAvailability {
            return sourceAvailability.message
        }
        if isRebuildingManifest {
            return "Destination manifest rebuild in progress..."
        }
        if let manifestAttention {
            return manifestAttention.importDisabledReason
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
        previewGeneration &+= 1
        isPreviewing = false
        previewResult = nil
        previewError = nil
        manifestAttention = nil
        sourceAvailability = nil
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

        let availability = Self.sourceAvailability(
            for: sourcePath,
            fileExists: FileManager.default.fileExists(atPath:)
        )
        guard availability == .available else {
            sourceAvailability = availability
            return
        }

        isPreviewing = true
        scanScanned = 0
        scanTotal = 0
        previewError = nil
        manifestAttention = nil
        sourceAvailability = nil
        let src = URL(fileURLWithPath: sourcePath)
        let dst = URL(fileURLWithPath: destinationPath)
        let cachedSource = sourceScanCache
        let request = PreviewRequest(
            generation: previewGeneration,
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )

        previewTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()

            do {
                let indexStatus = try await checker.buildIndex(at: dst)
                guard applyDestinationIndexStatus(indexStatus, for: request) else { return }

                let sourceFiles: [SourceFile]

                if let cachedSource, cachedSource.matches(path: request.sourcePath) {
                    sourceFiles = cachedSource.files
                } else {
                    let resolver = PhotosLibraryResolver.resolve(for: src)
                    sourceFiles = try await engine.scanSource(
                        source: src, resolver: resolver,
                        onProgress: { [weak self] scanned, total in
                            Task { @MainActor in
                                guard let self, self.isPreviewRequestCurrent(request) else { return }
                                self.scanScanned = scanned
                                self.scanTotal = total
                            }
                        }
                    )
                    guard isPreviewRequestCurrent(request) else { return }
                    sourceScanCache = SourceScanCache(
                        sourcePath: request.sourcePath,
                        files: sourceFiles,
                        timestamp: Date()
                    )
                }

                let preview = await engine.checkDuplicates(
                    sourceFiles: sourceFiles, duplicateChecker: checker
                )
                guard isPreviewRequestCurrent(request) else { return }
                previewResult = preview
            } catch {
                guard isPreviewRequestCurrent(request) else { return }
                previewError = error.localizedDescription
            }

            guard isPreviewRequestCurrent(request) else { return }
            isPreviewing = false
            scanScanned = 0
            scanTotal = 0
        }
    }

    func isPreviewRequestCurrent(_ request: PreviewRequest) -> Bool {
        !Task.isCancelled &&
            request.generation == previewGeneration &&
            request.sourcePath == sourcePath &&
            request.destinationPath == destinationPath
    }

    static func sourceAvailability(
        for sourcePath: String,
        fileExists: (String) -> Bool
    ) -> SourcePathAvailability {
        if let binding = VolumeBinding(role: .source, configuredPath: sourcePath),
           !fileExists(binding.mountRootPath) {
            return .volumeNotMounted(name: binding.volumeName)
        }
        return fileExists(sourcePath) ? .available : .folderUnavailable
    }

    /// Returns false when the preview has been cancelled, superseded, or needs user action.
    @discardableResult
    func applyDestinationIndexStatus(
        _ indexStatus: DestinationIndexStatus,
        for request: PreviewRequest
    ) -> Bool {
        guard isPreviewRequestCurrent(request) else { return false }
        guard case let .requiresUserAction(attention) = indexStatus else { return true }

        manifestAttention = attention
        previewResult = nil
        isPreviewing = false
        scanScanned = 0
        scanTotal = 0
        return false
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
                let indexStatus = try await checker.buildIndex(at: dst)
                if case let .requiresUserAction(attention) = indexStatus {
                    manifestAttention = attention
                    progress.isImporting = false
                    importTask = nil
                    return
                }

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

                let totalTransferBytes = filesToImport
                    .filter { !$0.isDuplicate }
                    .reduce(0) { $0 + $1.size }
                progress.beginImport(
                    totalFiles: filesToImport.count,
                    totalTransferBytes: totalTransferBytes
                )

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

    func rebuildManifest() {
        guard !destinationPath.isEmpty, !isRebuildingManifest else { return }

        let destinationURL = URL(fileURLWithPath: destinationPath)
        isRebuildingManifest = true
        previewError = nil
        previewResult = nil

        Task {
            let checker = DuplicateChecker()

            do {
                _ = try await checker.rebuildManifest(at: destinationURL)
                manifestAttention = nil
                isRebuildingManifest = false
                runPreview()
            } catch {
                previewError = error.localizedDescription
                isRebuildingManifest = false
            }
        }
    }

    func cleanup() {
        importTask?.cancel()
        previewTask?.cancel()
    }
}
