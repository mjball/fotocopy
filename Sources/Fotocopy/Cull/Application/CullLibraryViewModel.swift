import Foundation
import Observation

/// Owns the library-wide Organize workflow independently from the active Cull
/// review. Keeping this state separate prevents a review rescan from
/// cancelling a Trash confirmation or discarding an already-read library
/// summary.
@Observable
@MainActor
final class CullLibraryViewModel {
    var decisionScan: CullLibraryDecisionScan?
    var imageStatistics: LibraryImageStatistics?
    var isScanningImageStatistics = false
    var imageStatisticsError: String?
    var isScanningDecisions = false
    var scanStatus = ""
    var decisionError: String?
    var pendingTrashPlan: CullLibraryTrashPlan?
    var isTrashingRejects = false
    var trashResult: CullLibraryTrashResult?

    private var scanTask: Task<Void, Never>?
    private var imageStatisticsTask: Task<Void, Never>?

    var configuredLibraryURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: PreferenceKeys.destinationPath),
              !path.isEmpty else { return nil }
        return LibraryDecisionEngine.libraryRoot(forImportDestination: URL(fileURLWithPath: path))
    }

    func refreshImageStatisticsIfNeeded() {
        guard let libraryRoot = configuredLibraryURL else {
            imageStatistics = nil
            imageStatisticsError = nil
            return
        }
        guard imageStatistics?.libraryRootURL != libraryRoot else { return }
        refreshImageStatistics()
    }

    func refreshImageStatistics() {
        guard let libraryRoot = configuredLibraryURL,
              !isScanningImageStatistics,
              !isScanningDecisions,
              !isTrashingRejects else { return }
        imageStatisticsTask?.cancel()
        imageStatisticsError = nil
        isScanningImageStatistics = true
        let model = self
        imageStatisticsTask = Task {
            do {
                let statistics = try await Task.detached(priority: .utility) {
                    try LibraryDecisionEngine.scanImageStatistics(libraryRootURL: libraryRoot)
                }.value
                guard !Task.isCancelled else { return }
                model.imageStatistics = statistics
            } catch is CancellationError {
                // Replaced by a fuller Organize scan or a newer library scan.
            } catch {
                model.imageStatisticsError = error.localizedDescription
            }
            model.isScanningImageStatistics = false
            model.imageStatisticsTask = nil
        }
    }

    func refreshDecisionsIfNeeded() {
        guard let libraryRoot = configuredLibraryURL else {
            decisionScan = nil
            decisionError = "Choose an Import destination before reviewing library decisions."
            return
        }
        guard decisionScan?.libraryRootURL != libraryRoot else { return }
        refreshDecisions()
    }

    func refreshDecisions() {
        guard let libraryRoot = configuredLibraryURL,
              !isScanningDecisions,
              !isTrashingRejects else { return }
        scanTask?.cancel()
        imageStatisticsTask?.cancel()
        isScanningImageStatistics = false
        decisionError = nil
        trashResult = nil
        isScanningDecisions = true
        scanStatus = "Finding Keeps and Rejects…"
        let model = self
        scanTask = Task {
            do {
                let scan = try await Task.detached(priority: .userInitiated) {
                    try LibraryDecisionEngine.scan(libraryRootURL: libraryRoot)
                }.value
                guard !Task.isCancelled else { return }
                model.decisionScan = scan
                model.imageStatistics = scan.imageStatistics
                model.imageStatisticsError = nil
                model.scanStatus = "Found \(scan.decisions.count) decision\(scan.decisions.count == 1 ? "" : "s")"
            } catch is CancellationError {
                // Replaced by a newer library scan.
            } catch {
                model.decisionError = error.localizedDescription
            }
            model.isScanningDecisions = false
            model.scanTask = nil
        }
    }

    func prepareTrash() {
        guard let libraryRoot = configuredLibraryURL,
              !isTrashingRejects,
              !isScanningDecisions else { return }
        imageStatisticsTask?.cancel()
        isScanningImageStatistics = false
        decisionError = nil
        isScanningDecisions = true
        scanStatus = "Rechecking Rejects before Trash…"
        let model = self
        scanTask = Task {
            do {
                let scan = try await Task.detached(priority: .userInitiated) {
                    try LibraryDecisionEngine.scan(libraryRootURL: libraryRoot)
                }.value
                let plan = try LibraryDecisionEngine.makeTrashPlan(from: scan)
                guard !Task.isCancelled else { return }
                model.decisionScan = scan
                model.imageStatistics = scan.imageStatistics
                model.imageStatisticsError = nil
                model.pendingTrashPlan = plan
                model.scanStatus = "Rejects rechecked"
            } catch is CancellationError {
                // Replaced by a newer library scan.
            } catch {
                model.decisionError = error.localizedDescription
            }
            model.isScanningDecisions = false
            model.scanTask = nil
        }
    }

    func trashRejects(using plan: CullLibraryTrashPlan) {
        guard !isTrashingRejects else { return }
        pendingTrashPlan = nil
        decisionError = nil
        isTrashingRejects = true
        scanStatus = "Moving Rejects to Finder's Trash…"
        let model = self
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LibraryDecisionEngine.executeTrash(plan)
            }.value
            guard !Task.isCancelled else { return }
            model.trashResult = result
            model.isTrashingRejects = false
            model.scanStatus = "Trash finished"
            do {
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    try LibraryDecisionEngine.scan(libraryRootURL: plan.libraryRootURL)
                }.value
                model.decisionScan = refreshed
                model.imageStatistics = refreshed.imageStatistics
                model.imageStatisticsError = nil
            } catch {
                model.decisionError = "Files may have moved, but Library Decisions could not refresh: \(error.localizedDescription)"
            }
        }
    }

    func applyImageStatistics(after result: CullApplyResult, in folderURL: URL) {
        guard let statistics = imageStatistics,
              let libraryRoot = configuredLibraryURL,
              statistics.libraryRootURL == libraryRoot,
              LibraryDecisionEngine.isRecognizedDateFolder(folderURL, beneath: libraryRoot) else {
            return
        }
        guard let updated = statistics.applying(
            rawRelocations: result.rawRelocations,
            rawFileByteCounts: result.rawFileByteCounts,
            in: folderURL
        ) else {
            refreshImageStatistics()
            return
        }
        imageStatistics = updated
    }

}
