import Foundation
import Testing
@testable import Fotocopy

@Suite
struct QuickExportNotificationTests {
    @Test func completeExportNamesDestinationAndPluralizesCount() {
        let destination = URL(fileURLWithPath: "/Users/test/Exports")
        let result = QuickExportResult(
            exportedURLs: [
                destination.appendingPathComponent("IMG_0001.jpg"),
                destination.appendingPathComponent("IMG_0002.jpg")
            ],
            failures: []
        )

        let notification = QuickExportNotification.completed(
            result: result,
            destinationFolderURL: destination
        )

        #expect(notification.title == "Quick Export Complete")
        #expect(notification.body == "Exported 2 JPEG images to Exports.")
    }

    @Test func partialExportIncludesBothResultAndFailure() {
        let destination = URL(fileURLWithPath: "/Users/test/Exports")
        let failedURL = URL(fileURLWithPath: "/Users/test/IMG_0001.CR3")
        let result = QuickExportResult(
            exportedURLs: [destination.appendingPathComponent("IMG_0002.jpg")],
            failures: [QuickExportFailure(sourceURL: failedURL, message: "Converter failed.")]
        )

        let notification = QuickExportNotification.completed(
            result: result,
            destinationFolderURL: destination
        )

        #expect(notification.title == "Quick Export Partially Complete")
        #expect(notification.body == "Exported 1 JPEG image to Exports. Could not export IMG_0001.CR3. Converter failed.")
    }

    @Test func failedExportIsClearlyLabeled() {
        let failedURL = URL(fileURLWithPath: "/Users/test/IMG_0001.CR3")
        let result = QuickExportResult(
            exportedURLs: [],
            failures: [QuickExportFailure(sourceURL: failedURL, message: "Converter failed.")]
        )

        let notification = QuickExportNotification.completed(
            result: result,
            destinationFolderURL: URL(fileURLWithPath: "/Users/test/Exports")
        )

        #expect(notification.title == "Quick Export Failed")
        #expect(notification.body == "Could not export IMG_0001.CR3. Converter failed.")
    }
}
