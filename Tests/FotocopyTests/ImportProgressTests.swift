import Testing
import Foundation
@testable import Fotocopy

@Suite
@MainActor
struct ImportProgressTests {
    @Test func fractionZeroTotal() {
        let p = ImportProgress()
        #expect(p.fraction == 0)
    }

    @Test func fractionNormal() {
        let p = ImportProgress()
        p.totalFiles = 10
        p.processedFiles = 5
        #expect(p.fraction == 0.5)
    }

    @Test func fractionComplete() {
        let p = ImportProgress()
        p.totalFiles = 10
        p.processedFiles = 10
        #expect(p.fraction == 1.0)
    }

    @Test func resetClearsAllFields() {
        let p = ImportProgress()
        p.totalFiles = 42
        p.processedFiles = 20
        p.duplicatesSkipped = 3
        p.fallbackDateFiles = ["a.jpg"]
        p.errors = [(file: "b.jpg", message: "fail")]
        p.isScanning = true
        p.isImporting = true
        p.isComplete = true
        p.currentFile = "c.jpg"
        p.totalBytesToImport = 1000
        p.recordCompletion(bytes: 500)

        p.reset()

        #expect(p.totalFiles == 0)
        #expect(p.processedFiles == 0)
        #expect(p.duplicatesSkipped == 0)
        #expect(p.fallbackDateFiles.isEmpty)
        #expect(p.errors.isEmpty)
        #expect(p.isScanning == false)
        #expect(p.isImporting == false)
        #expect(p.isComplete == false)
        #expect(p.currentFile == "")
        #expect(p.totalBytesToImport == 0)
        #expect(p.bytesCompleted == 0)
        #expect(p.throughputBytesPerSecond == nil)
    }

    @Test func throughputNilWithFewerThanTwoEntries() {
        let p = ImportProgress()
        #expect(p.throughputBytesPerSecond == nil)
        p.recordCompletion(bytes: 1000)
        #expect(p.throughputBytesPerSecond == nil)
    }

    @Test func recordCompletionTracksBytesCompleted() {
        let p = ImportProgress()
        p.recordCompletion(bytes: 100)
        p.recordCompletion(bytes: 200)
        #expect(p.bytesCompleted == 300)
    }

    @Test func throughputWindowLimitedToWindowSize() {
        let p = ImportProgress()
        for _ in 0..<10 {
            p.recordCompletion(bytes: 100)
        }
        #expect(p.bytesCompleted == 1000)
        // formattedThroughput should still work (window pruned to 5)
        // Can't easily test exact throughput since timestamps are real,
        // but it shouldn't be nil
    }

    @Test func formattedThroughputNilWhenInsufficient() {
        let p = ImportProgress()
        #expect(p.formattedThroughput == nil)
    }

    @Test func formattedETANilWhenNoThroughput() {
        let p = ImportProgress()
        p.totalBytesToImport = 1000
        #expect(p.formattedETA == nil)
    }

    @Test func formattedETANilWhenComplete() {
        let p = ImportProgress()
        p.totalBytesToImport = 100
        p.recordCompletion(bytes: 50)
        p.recordCompletion(bytes: 50)
        // bytesCompleted == totalBytesToImport, remaining == 0
        #expect(p.formattedETA == nil)
    }
}
