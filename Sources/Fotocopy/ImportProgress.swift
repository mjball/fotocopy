import Foundation
import SwiftUI

private let importProgressClock = ContinuousClock()

@Observable
@MainActor
final class ImportProgress {
    static let minimumWarmElapsed = Duration.seconds(2)
    static let minimumWarmBytes = 64 * 1024 * 1024
    static let throughputTauSeconds = 6.0

    var totalFiles = 0
    var processedFiles = 0
    var duplicatesSkipped = 0
    var failedFiles = 0
    var fallbackDateFiles: [String] = []
    var errors: [(file: String, message: String)] = []
    var isScanning = false
    var isImporting = false
    var isComplete = false
    var currentFile = ""
    var totalTransferBytes = 0
    var transferredBytes = 0
    var settledTransferBytes = 0

    private let now: () -> ContinuousClock.Instant
    private var importStartedAt: ContinuousClock.Instant?
    private var lastSuccessfulSample: (instant: ContinuousClock.Instant, cumulativeBytes: Int)?
    private var successfulSampleCount = 0
    private var smoothedThroughputEstimate: Double?

    init(now: @escaping () -> ContinuousClock.Instant = { importProgressClock.now }) {
        self.now = now
    }

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
    }

    var remainingTransferBytes: Int {
        max(0, totalTransferBytes - settledTransferBytes)
    }

    var throughputBytesPerSecond: Double? {
        guard isThroughputWarm,
              let estimate = smoothedThroughputEstimate,
              estimate.isFinite,
              estimate > 0 else { return nil }
        return estimate
    }

    var formattedThroughput: String? {
        guard let bps = throughputBytesPerSecond else { return nil }
        if bps >= 1_000_000_000 {
            return String(format: "%.1f GB/s", bps / 1_000_000_000)
        } else if bps >= 1_000_000 {
            return String(format: "%.0f MB/s", bps / 1_000_000)
        } else if bps >= 1_000 {
            return String(format: "%.0f KB/s", bps / 1_000)
        } else {
            return String(format: "%.0f B/s", bps)
        }
    }

    var formattedETA: String? {
        let remaining = remainingTransferBytes
        guard remaining > 0 else { return nil }
        guard let bps = throughputBytesPerSecond, bps > 0 else {
            return isImporting ? "Estimating..." : nil
        }
        let seconds = max(1, Int(ceil(Double(remaining) / bps)))
        if seconds >= 3600 {
            return "~\(seconds / 3600)h \((seconds % 3600) / 60)m"
        } else if seconds >= 60 {
            return "~\(seconds / 60)m \(seconds % 60)s"
        } else {
            return "~\(seconds)s"
        }
    }

    func beginImport(totalFiles: Int, totalTransferBytes: Int) {
        self.totalFiles = totalFiles
        self.processedFiles = 0
        self.duplicatesSkipped = 0
        self.failedFiles = 0
        self.currentFile = ""
        self.totalTransferBytes = totalTransferBytes
        self.transferredBytes = 0
        self.settledTransferBytes = 0
        self.isImporting = true
        self.isComplete = false
        self.importStartedAt = now()
        self.lastSuccessfulSample = nil
        self.successfulSampleCount = 0
        self.smoothedThroughputEstimate = nil
    }

    func recordDuplicateSkipped() {
        duplicatesSkipped += 1
        processedFiles += 1
    }

    func recordSuccessfulTransfer(bytes: Int) {
        let transferBytes = max(0, bytes)
        processedFiles += 1
        transferredBytes += transferBytes
        settledTransferBytes += transferBytes

        guard transferBytes > 0 else { return }

        let sampleTime = now()
        if let lastSuccessfulSample {
            successfulSampleCount += 1

            let deltaSeconds = Self.seconds(since: lastSuccessfulSample.instant, to: sampleTime)
            if deltaSeconds > 0 {
                let deltaBytes = transferredBytes - lastSuccessfulSample.cumulativeBytes
                let instantaneousRate = Double(deltaBytes) / deltaSeconds

                if let previousEstimate = smoothedThroughputEstimate {
                    let alpha = Self.ewmaAlpha(deltaSeconds: deltaSeconds)
                    smoothedThroughputEstimate = previousEstimate
                        + alpha * (instantaneousRate - previousEstimate)
                } else if let importStartedAt {
                    let overallSeconds = Self.seconds(since: importStartedAt, to: sampleTime)
                    smoothedThroughputEstimate = overallSeconds > 0
                        ? Double(transferredBytes) / overallSeconds
                        : instantaneousRate
                } else {
                    smoothedThroughputEstimate = instantaneousRate
                }
            }
        } else {
            successfulSampleCount = 1
            importStartedAt = importStartedAt ?? sampleTime
        }

        lastSuccessfulSample = (sampleTime, transferredBytes)
    }

    func recordFailedTransfer(bytes: Int) {
        failedFiles += 1
        processedFiles += 1
        settledTransferBytes += max(0, bytes)
    }

    func reset() {
        totalFiles = 0
        processedFiles = 0
        duplicatesSkipped = 0
        failedFiles = 0
        fallbackDateFiles = []
        errors = []
        isScanning = false
        isImporting = false
        isComplete = false
        currentFile = ""
        totalTransferBytes = 0
        transferredBytes = 0
        settledTransferBytes = 0
        importStartedAt = nil
        lastSuccessfulSample = nil
        successfulSampleCount = 0
        smoothedThroughputEstimate = nil
    }

    private var isThroughputWarm: Bool {
        guard successfulSampleCount >= 2 else { return false }
        return transferredBytes >= Self.minimumWarmBytes
            || elapsedSinceImportStarted >= Self.seconds(Self.minimumWarmElapsed)
    }

    private var elapsedSinceImportStarted: Double {
        guard let importStartedAt else { return 0 }
        return Self.seconds(since: importStartedAt, to: now())
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func seconds(since start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        seconds(start.duration(to: end))
    }

    private static func ewmaAlpha(deltaSeconds: Double) -> Double {
        1 - Foundation.exp(-deltaSeconds / throughputTauSeconds)
    }
}
