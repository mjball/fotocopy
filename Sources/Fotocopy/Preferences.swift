import Foundation

enum TransferMode: String, CaseIterable {
    case copy
    case move
}

enum PreferenceKeys {
    static let sourcePath = "sourcePath"
    static let destinationPath = "destinationPath"
    static let transferMode = "transferMode"
    static let autoOpenVolume = "autoOpenVolume"
    static let ejectSource = "ejectSource"
    static let ejectDestination = "ejectDestination"
}
