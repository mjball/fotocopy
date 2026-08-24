import Foundation

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
