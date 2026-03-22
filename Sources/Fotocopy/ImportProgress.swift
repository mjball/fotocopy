import Foundation
import SwiftUI

@Observable
@MainActor
final class ImportProgress {
    static let throughputWindowSize = 5

    var totalFiles = 0
    var processedFiles = 0
    var duplicatesSkipped = 0
    var fallbackDateFiles: [String] = []
    var errors: [(file: String, message: String)] = []
    var isScanning = false
    var isImporting = false
    var isComplete = false
    var currentFile = ""
    var totalBytesToImport = 0
    var bytesCompleted = 0

    private var throughputWindow: [(date: Date, size: Int)] = []

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
    }

    func recordCompletion(bytes: Int) {
        bytesCompleted += bytes
        throughputWindow.append((date: Date(), size: bytes))
        if throughputWindow.count > Self.throughputWindowSize {
            throughputWindow.removeFirst(throughputWindow.count - Self.throughputWindowSize)
        }
    }

    var throughputBytesPerSecond: Double? {
        guard throughputWindow.count >= 2 else { return nil }
        let elapsed = throughputWindow.last!.date.timeIntervalSince(throughputWindow.first!.date)
        guard elapsed > 0 else { return nil }
        let totalBytes = throughputWindow.reduce(0) { $0 + $1.size }
        return Double(totalBytes) / elapsed
    }

    var formattedThroughput: String? {
        guard let bps = throughputBytesPerSecond else { return nil }
        if bps >= 1_000_000_000 {
            return String(format: "%.1f GB/s", bps / 1_000_000_000)
        } else {
            return String(format: "%.0f MB/s", bps / 1_000_000)
        }
    }

    var formattedETA: String? {
        guard let bps = throughputBytesPerSecond, bps > 0 else { return nil }
        let remaining = totalBytesToImport - bytesCompleted
        guard remaining > 0 else { return nil }
        let seconds = Int(Double(remaining) / bps)
        if seconds >= 3600 {
            return "~\(seconds / 3600)h \((seconds % 3600) / 60)m"
        } else if seconds >= 60 {
            return "~\(seconds / 60)m \(seconds % 60)s"
        } else {
            return "~\(seconds)s"
        }
    }

    func reset() {
        totalFiles = 0
        processedFiles = 0
        duplicatesSkipped = 0
        fallbackDateFiles = []
        errors = []
        isScanning = false
        isImporting = false
        isComplete = false
        currentFile = ""
        totalBytesToImport = 0
        bytesCompleted = 0
        throughputWindow = []
    }
}
