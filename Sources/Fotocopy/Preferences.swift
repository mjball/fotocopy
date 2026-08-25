import Foundation
import SwiftUI

enum TransferMode: String, CaseIterable {
    case copy
    case move
}

enum PreferenceKeys {
    static let activeWorkspace = "activeWorkspace"
    static let sourcePath = "sourcePath"
    static let destinationPath = "destinationPath"
    static let transferMode = "transferMode"
    static let autoOpenSource = "autoOpenSource"
    static let autoOpenDestination = "autoOpenDestination"
    static let ejectSource = "ejectSource"
    static let ejectDestination = "ejectDestination"
    static let excludedExtensions = "excludedExtensions"
    static let excludedCameraModels = "excludedCameraModels"
    static let recentCullFolders = "recentCullFolders"
    static let lastCullFolder = "lastCullFolder"
    static let cullScanWorkerCount = "cullScanWorkerCount"
    static let cullPreviewHeight = "cullPreviewHeight"
}

enum CullSettings {
    static let availableScanWorkerCounts = [1, 2, 4, 6]

    static var scanWorkerCount: Int {
        let savedCount = UserDefaults.standard.integer(forKey: PreferenceKeys.cullScanWorkerCount)
        return availableScanWorkerCounts.contains(savedCount) ? savedCount : 4
    }
}

struct FotocopySettingsView: View {
    @AppStorage(PreferenceKeys.cullScanWorkerCount) private var scanWorkerCount = 4

    var body: some View {
        Form {
            Section("Cull") {
                Picker("Scan workers", selection: $scanWorkerCount) {
                    ForEach(CullSettings.availableScanWorkerCounts, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }

                Text("Controls how many photo files Fotocopy reads at once while finding bursts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding()
    }
}

struct ImportFilter: Sendable {
    var excludedExtensions: Set<String> = []
    var excludedCameraModels: Set<String> = []
    var dateFrom: Date? = nil
    var dateTo: Date? = nil

    func includes(_ file: PreviewFile) -> Bool {
        if excludedExtensions.contains(file.ext) { return false }
        if let model = file.cameraModel, excludedCameraModels.contains(model) { return false }
        if let from = dateFrom, let date = file.date, date < from { return false }
        if let to = dateTo, let date = file.date,
           let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: to),
           date > endOfDay { return false }
        return true
    }
}
