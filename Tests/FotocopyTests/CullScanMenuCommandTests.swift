import Testing
@testable import Fotocopy

@Suite
struct CullScanMenuCommandTests {
    @Test func showsRescanWhenIdleAndCancelScanWhenRunning() {
        #expect(CullScanMenuCommand.title(isScanning: false) == "Rescan")
        #expect(CullScanMenuCommand.title(isScanning: true) == "Cancel Scan")
    }

    @Test func onlyEnablesRescanForAnIdleActiveCullFolder() {
        #expect(
            CullScanMenuCommand.isEnabled(
                isCullActive: true,
                isScanning: false,
                isMoving: false,
                hasFolder: true
            )
        )
        #expect(
            !CullScanMenuCommand.isEnabled(
                isCullActive: false,
                isScanning: false,
                isMoving: false,
                hasFolder: true
            )
        )
        #expect(
            !CullScanMenuCommand.isEnabled(
                isCullActive: true,
                isScanning: false,
                isMoving: false,
                hasFolder: false
            )
        )
        #expect(
            !CullScanMenuCommand.isEnabled(
                isCullActive: true,
                isScanning: false,
                isMoving: true,
                hasFolder: true
            )
        )
    }

    @Test func keepsCancelScanAvailableForAnInFlightScan() {
        #expect(
            CullScanMenuCommand.isEnabled(
                isCullActive: true,
                isScanning: true,
                isMoving: false,
                hasFolder: true
            )
        )
        #expect(
            CullScanMenuCommand.isEnabled(
                isCullActive: false,
                isScanning: true,
                isMoving: false,
                hasFolder: false
            )
        )
    }
}
