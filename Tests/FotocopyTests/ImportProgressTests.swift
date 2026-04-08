import Testing
import Foundation
@testable import Fotocopy

@Suite
@MainActor
struct ImportProgressTests {
    private final class TestTime {
        var instant: ContinuousClock.Instant

        init(instant: ContinuousClock.Instant = ContinuousClock().now) {
            self.instant = instant
        }

        func advance(by duration: Duration) {
            instant = instant.advanced(by: duration)
        }
    }

    private func makeProgress() -> (progress: ImportProgress, time: TestTime) {
        let time = TestTime()
        let progress = ImportProgress(now: { time.instant })
        return (progress, time)
    }

    @Test func fractionZeroTotal() {
        let progress = ImportProgress()
        #expect(progress.fraction == 0)
    }

    @Test func fractionNormal() {
        let progress = ImportProgress()
        progress.totalFiles = 10
        progress.processedFiles = 5
        #expect(progress.fraction == 0.5)
    }

    @Test func fractionComplete() {
        let progress = ImportProgress()
        progress.totalFiles = 10
        progress.processedFiles = 10
        #expect(progress.fraction == 1.0)
    }

    @Test func resetClearsAllFields() {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 42, totalTransferBytes: 1_000)
        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 500)
        progress.recordFailedTransfer(bytes: 100)
        progress.recordDuplicateSkipped()
        progress.fallbackDateFiles = ["a.jpg"]
        progress.errors = [(file: "b.jpg", message: "fail")]
        progress.isScanning = true
        progress.isComplete = true
        progress.currentFile = "c.jpg"

        progress.reset()

        #expect(progress.totalFiles == 0)
        #expect(progress.processedFiles == 0)
        #expect(progress.duplicatesSkipped == 0)
        #expect(progress.failedFiles == 0)
        #expect(progress.fallbackDateFiles.isEmpty)
        #expect(progress.errors.isEmpty)
        #expect(progress.isScanning == false)
        #expect(progress.isImporting == false)
        #expect(progress.isComplete == false)
        #expect(progress.currentFile == "")
        #expect(progress.totalTransferBytes == 0)
        #expect(progress.transferredBytes == 0)
        #expect(progress.settledTransferBytes == 0)
        #expect(progress.throughputBytesPerSecond == nil)
    }

    @Test func throughputNilWithFewerThanTwoSuccessfulSamples() {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 1, totalTransferBytes: 1_000)

        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 1_000)

        #expect(progress.throughputBytesPerSecond == nil)
        #expect(progress.formattedThroughput == nil)
    }

    @Test func recordSuccessfulTransferTracksTransferredAndSettledBytes() {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 2, totalTransferBytes: 300)

        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 100)
        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 200)

        #expect(progress.processedFiles == 2)
        #expect(progress.transferredBytes == 300)
        #expect(progress.settledTransferBytes == 300)
        #expect(progress.remainingTransferBytes == 0)
    }

    @Test func duplicateSkipDoesNotAffectTransferBytes() {
        let progress = ImportProgress()
        progress.beginImport(totalFiles: 3, totalTransferBytes: 500)
        progress.recordDuplicateSkipped()

        #expect(progress.processedFiles == 1)
        #expect(progress.duplicatesSkipped == 1)
        #expect(progress.transferredBytes == 0)
        #expect(progress.settledTransferBytes == 0)
        #expect(progress.remainingTransferBytes == 500)
    }

    @Test func failedTransferSettlesBytesWithoutThroughput() {
        let progress = ImportProgress()
        progress.beginImport(totalFiles: 1, totalTransferBytes: 1_024)
        progress.recordFailedTransfer(bytes: 1_024)

        #expect(progress.processedFiles == 1)
        #expect(progress.failedFiles == 1)
        #expect(progress.transferredBytes == 0)
        #expect(progress.settledTransferBytes == 1_024)
        #expect(progress.throughputBytesPerSecond == nil)
        #expect(progress.formattedETA == nil)
    }

    @Test func formattedETAShowsEstimatingUntilWarm() {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 4, totalTransferBytes: 40_000_000)

        time.advance(by: .milliseconds(400))
        progress.recordSuccessfulTransfer(bytes: 10_000_000)
        time.advance(by: .milliseconds(400))
        progress.recordSuccessfulTransfer(bytes: 10_000_000)

        #expect(progress.throughputBytesPerSecond == nil)
        #expect(progress.formattedThroughput == nil)
        #expect(progress.formattedETA == "Estimating...")
    }

    @Test func burstCompletionsUseReasonableWarmupRate() throws {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 2, totalTransferBytes: 200_000_000)

        time.advance(by: .seconds(2))
        progress.recordSuccessfulTransfer(bytes: 100_000_000)
        time.advance(by: .milliseconds(10))
        progress.recordSuccessfulTransfer(bytes: 100_000_000)

        let throughput = try #require(progress.throughputBytesPerSecond)
        #expect(throughput > 80_000_000)
        #expect(throughput < 150_000_000)
    }

    @Test func ewmaAdaptsSmoothlyToRateChanges() throws {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 4, totalTransferBytes: 400_000_000)

        time.advance(by: .seconds(2))
        progress.recordSuccessfulTransfer(bytes: 100_000_000)
        time.advance(by: .seconds(2))
        progress.recordSuccessfulTransfer(bytes: 100_000_000)
        let steady = try #require(progress.throughputBytesPerSecond)

        time.advance(by: .seconds(6))
        progress.recordSuccessfulTransfer(bytes: 100_000_000)
        let slowed = try #require(progress.throughputBytesPerSecond)

        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 100_000_000)
        let recovered = try #require(progress.throughputBytesPerSecond)

        #expect(steady > 45_000_000)
        #expect(steady < 55_000_000)
        #expect(slowed < steady)
        #expect(slowed > 20_000_000)
        #expect(recovered > slowed)
        #expect(recovered < 100_000_000)
    }

    @Test func etaClampsToAtLeastOneSecondWhileWorkRemains() {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 3, totalTransferBytes: 128_000_001)

        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 64_000_000)
        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 64_000_000)

        #expect(progress.remainingTransferBytes == 1)
        #expect(progress.formattedETA == "~1s")
    }

    @Test func formattedETANilWhenComplete() {
        let (progress, time) = makeProgress()
        progress.beginImport(totalFiles: 2, totalTransferBytes: 100)

        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 50)
        time.advance(by: .seconds(1))
        progress.recordSuccessfulTransfer(bytes: 50)

        #expect(progress.formattedETA == nil)
    }
}
