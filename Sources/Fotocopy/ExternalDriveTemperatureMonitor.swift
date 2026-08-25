import AppKit
import Foundation
import SwiftUI

struct ExternalDriveTemperatureReading: Identifiable, Equatable, Sendable {
    let id: String
    let volumeName: String
    let mountURL: URL
    let temperatureCelsius: Int?

    var temperatureLabel: String {
        guard let temperatureCelsius else { return "Temperature unavailable" }
        return "\(temperatureCelsius) °C"
    }
}

/// Polls macOS's built-in disk utility for SMART data exposed by mounted
/// external SSDs. Unlike `smartctl`, this needs neither a password prompt nor
/// a privileged helper. Some enclosures do not expose a temperature; those
/// drives remain visible in the chip with an unavailable reading.
@Observable
@MainActor
final class ExternalDriveTemperatureMonitor {
    private(set) var readings: [ExternalDriveTemperatureReading] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    private var refreshLoop: Task<Void, Never>?
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    var primaryReading: ExternalDriveTemperatureReading? {
        readings.first(where: { $0.temperatureCelsius != nil }) ?? readings.first
    }

    var toolbarLabel: String {
        guard let primaryReading else { return "" }
        if readings.count == 1 {
            return "\(primaryReading.volumeName) · \(primaryReading.temperatureLabel)"
        }
        return "\(readings.count) external SSDs · \(primaryReading.temperatureLabel)"
    }

    func start() {
        guard refreshLoop == nil else { return }
        installVolumeObservers()
        refresh()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            let readings = await Task.detached(priority: .utility) {
                ExternalDriveTemperatureReader.readMountedExternalSSDs()
            }.value
            guard let self else { return }
            self.readings = readings
            self.lastUpdated = Date()
            self.isRefreshing = false
        }
    }

    private func installVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

enum ExternalDriveTemperatureReader {
    static func readMountedExternalSSDs() -> [ExternalDriveTemperatureReading] {
        let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        var seenDisks = Set<String>()
        let readings = volumeURLs.compactMap { volumeURL -> ExternalDriveTemperatureReading? in
            guard let information = diskInformation(for: volumeURL),
                  let reading = reading(from: information, mountURL: volumeURL),
                  seenDisks.insert(reading.id).inserted else {
                return nil
            }
            return reading
        }
        return readings.sorted {
            $0.volumeName.localizedStandardCompare($1.volumeName) == .orderedAscending
        }
    }

    static func reading(
        from information: [String: Any],
        mountURL: URL
    ) -> ExternalDriveTemperatureReading? {
        guard boolValue(information["Internal"]) == false,
              boolValue(information["SolidState"]) == true else {
            return nil
        }

        let identifier = stringValue(information["ParentWholeDisk"])
            ?? stringValue(information["DeviceIdentifier"])
        guard let identifier, !identifier.isEmpty else { return nil }

        let volumeName = stringValue(information["VolumeName"])
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? mountURL.lastPathComponent
        let smartData = information["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        return ExternalDriveTemperatureReading(
            id: identifier,
            volumeName: volumeName,
            mountURL: mountURL,
            temperatureCelsius: temperatureCelsius(from: smartData)
        )
    }

    static func temperatureCelsius(from smartData: [String: Any]) -> Int? {
        let candidates = smartData.compactMap { key, value -> (priority: Int, value: Double)? in
            let normalizedKey = key.uppercased()
            guard normalizedKey.contains("TEMPERATURE"),
                  !normalizedKey.contains("THRESHOLD"),
                  !normalizedKey.contains("THROTTLE"),
                  let rawValue = doubleValue(value) else {
                return nil
            }
            return (normalizedKey == "TEMPERATURE" ? 0 : 1, rawValue)
        }
        guard let rawTemperature = candidates.sorted(by: { $0.priority < $1.priority }).first?.value else {
            return nil
        }

        // NVMe SMART temperatures are normally Kelvin (for example, BAR
        // exposes 321 for a 48 °C drive). SATA adapters commonly use Celsius.
        let celsius = rawTemperature >= 200 ? rawTemperature - 273.15 : rawTemperature
        guard (-20...130).contains(celsius) else { return nil }
        return Int(celsius.rounded())
    }

    private static func diskInformation(for volumeURL: URL) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", volumeURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        return nil
    }

    private static func doubleValue(_ value: Any) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

struct ExternalDriveTemperatureToolbarChip: View {
    @Bindable var monitor: ExternalDriveTemperatureMonitor

    var body: some View {
        if monitor.primaryReading != nil {
            Menu {
                ForEach(monitor.readings) { reading in
                    Text("\(reading.volumeName) · \(reading.temperatureLabel)")
                }
                Divider()
                Button("Refresh Drive Temperature") {
                    monitor.refresh()
                }
                .disabled(monitor.isRefreshing)
            } label: {
                Label(monitor.toolbarLabel, systemImage: "thermometer.medium")
                    .foregroundStyle(chipColor)
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .help(helpText)
        }
    }

    private var chipColor: Color {
        guard let temperature = monitor.primaryReading?.temperatureCelsius else { return .secondary }
        switch temperature {
        case 61...: return .red
        case 51...: return .orange
        default: return .primary
        }
    }

    private var helpText: String {
        guard let updated = monitor.lastUpdated else {
            return "External SSD temperature"
        }
        return "External SSD temperature · updated \(updated.formatted(date: .omitted, time: .standard))"
    }
}
