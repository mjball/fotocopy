import Foundation
import SwiftUI

@Observable
@MainActor
final class ImportProgress {
    var totalFiles = 0
    var processedFiles = 0
    var duplicatesSkipped = 0
    var fallbackDateFiles: [String] = []
    var errors: [(file: String, message: String)] = []
    var isScanning = false
    var isImporting = false
    var isComplete = false
    var currentFile = ""

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
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
    }
}
