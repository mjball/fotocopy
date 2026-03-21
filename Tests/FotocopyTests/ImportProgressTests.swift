import Testing
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
    }
}
