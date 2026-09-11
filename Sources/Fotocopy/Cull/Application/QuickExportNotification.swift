import Foundation
import UserNotifications

struct QuickExportNotification: Equatable, Sendable {
    let title: String
    let body: String

    static func completed(
        result: QuickExportResult,
        destinationFolderURL: URL
    ) -> QuickExportNotification {
        let exportedCount = result.exportedURLs.count
        let destination = destinationFolderURL.lastPathComponent

        if result.failures.isEmpty {
            return QuickExportNotification(
                title: "Quick Export Complete",
                body: "Exported \(exportedCount) JPEG \(exportedCount == 1 ? "image" : "images") to \(destination)."
            )
        }

        let failedNames = result.failures.map { $0.sourceURL.lastPathComponent }.joined(separator: ", ")
        let failureSummary = "Could not export \(failedNames). \(result.failures.first?.message ?? "")"
        if exportedCount == 0 {
            return QuickExportNotification(
                title: "Quick Export Failed",
                body: failureSummary
            )
        }

        return QuickExportNotification(
            title: "Quick Export Partially Complete",
            body: "Exported \(exportedCount) JPEG \(exportedCount == 1 ? "image" : "images") to \(destination). \(failureSummary)"
        )
    }

    static func failed(_ error: Error) -> QuickExportNotification {
        QuickExportNotification(
            title: "Could not export JPEGs",
            body: error.localizedDescription
        )
    }
}

protocol QuickExportNotifying: Sendable {
    func deliver(_ notification: QuickExportNotification) async
}

struct SystemQuickExportNotifier: QuickExportNotifying {
    func deliver(_ notification: QuickExportNotification) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        guard await isAuthorized(toDeliverFrom: center, settings: settings) else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private func isAuthorized(
        toDeliverFrom center: UNUserNotificationCenter,
        settings: UNNotificationSettings
    ) async -> Bool {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined:
            (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            false
        @unknown default:
            false
        }
    }
}
