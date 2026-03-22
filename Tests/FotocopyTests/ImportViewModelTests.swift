import Testing
import Foundation
@testable import Fotocopy

@Suite
@MainActor
struct ImportViewModelTests {

    // MARK: - importDisabledReason

    @Test func disabledWhenPathsEmpty() {
        let vm = ImportViewModel()
        #expect(vm.importDisabledReason == "Select source and destination folders")
    }

    @Test func disabledWhenSourceOnly() {
        let vm = ImportViewModel()
        vm.sourcePath = "/some/source"
        #expect(vm.importDisabledReason == "Select source and destination folders")
    }

    @Test func disabledWhenDestinationOnly() {
        let vm = ImportViewModel()
        vm.destinationPath = "/some/dest"
        #expect(vm.importDisabledReason == "Select source and destination folders")
    }

    @Test func disabledWhenPreviewing() {
        let vm = ImportViewModel()
        vm.sourcePath = "/source"
        vm.destinationPath = "/dest"
        vm.isPreviewing = true
        #expect(vm.importDisabledReason == "Scanning in progress...")
    }

    @Test func disabledWhenNoFilesFound() {
        let vm = ImportViewModel()
        vm.sourcePath = "/source"
        vm.destinationPath = "/dest"
        vm.previewResult = PreviewResult(files: [])
        #expect(vm.importDisabledReason == "No supported files found in source")
    }

    @Test func disabledWhenAllFiltered() {
        let vm = ImportViewModel()
        vm.sourcePath = "/source"
        vm.destinationPath = "/dest"
        vm.excludedExtensionsRaw = "jpg"

        let file = PreviewFile(
            url: URL(fileURLWithPath: "/test.jpg"),
            filename: "test.jpg", ext: "jpg", size: 100,
            date: Date(), dateSource: .filesystem, cameraModel: nil, isDuplicate: false
        )
        vm.previewResult = PreviewResult(files: [file])

        #expect(vm.importDisabledReason == "No new files match current filters")
    }

    @Test func disabledWhenAllDuplicates() {
        let vm = ImportViewModel()
        vm.sourcePath = "/source"
        vm.destinationPath = "/dest"

        let file = PreviewFile(
            url: URL(fileURLWithPath: "/test.jpg"),
            filename: "test.jpg", ext: "jpg", size: 100,
            date: Date(), dateSource: .filesystem, cameraModel: nil, isDuplicate: true
        )
        vm.previewResult = PreviewResult(files: [file])

        #expect(vm.importDisabledReason == "No new files match current filters")
    }

    @Test func enabledWhenReady() {
        let vm = ImportViewModel()
        vm.sourcePath = "/source"
        vm.destinationPath = "/dest"

        let file = PreviewFile(
            url: URL(fileURLWithPath: "/test.jpg"),
            filename: "test.jpg", ext: "jpg", size: 100,
            date: Date(), dateSource: .filesystem, cameraModel: nil, isDuplicate: false
        )
        vm.previewResult = PreviewResult(files: [file])

        #expect(vm.importDisabledReason == nil)
        #expect(vm.isImportDisabled == false)
    }

    @Test func disabledWhenWaitingForScan() {
        let vm = ImportViewModel()
        vm.sourcePath = "/source"
        vm.destinationPath = "/dest"
        // previewResult is nil, not previewing
        #expect(vm.importDisabledReason == "Waiting for scan")
    }

    // MARK: - Source scan cache

    @Test func cacheMatchesSamePath() {
        let cache = SourceScanCache(sourcePath: "/source", files: [], timestamp: Date())
        #expect(cache.matches(path: "/source") == true)
    }

    @Test func cacheDoesNotMatchDifferentPath() {
        let cache = SourceScanCache(sourcePath: "/source", files: [], timestamp: Date())
        #expect(cache.matches(path: "/other") == false)
    }

    @Test func cacheExpires() {
        let old = Date().addingTimeInterval(-301)
        let cache = SourceScanCache(sourcePath: "/source", files: [], timestamp: old)
        #expect(cache.isValid == false)
        #expect(cache.matches(path: "/source") == false)
    }

    @Test func cacheValidWithinTTL() {
        let recent = Date().addingTimeInterval(-60)
        let cache = SourceScanCache(sourcePath: "/source", files: [], timestamp: recent)
        #expect(cache.isValid == true)
        #expect(cache.matches(path: "/source") == true)
    }

    // MARK: - Filter parsing

    @Test func parsesExcludedExtensions() {
        let vm = ImportViewModel()
        vm.excludedExtensionsRaw = "jpg,png,heic"
        #expect(vm.excludedExtensions == ["jpg", "png", "heic"])
    }

    @Test func parsesEmptyExcludedExtensions() {
        let vm = ImportViewModel()
        vm.excludedExtensionsRaw = ""
        #expect(vm.excludedExtensions.isEmpty)
    }

    @Test func parsesExcludedCameraModels() {
        let vm = ImportViewModel()
        vm.excludedCameraModelsRaw = "iPhone 15 Pro,Canon EOS R6"
        #expect(vm.excludedCameraModels == ["iPhone 15 Pro", "Canon EOS R6"])
    }

    @Test func activeFilterIncorporatesAllState() {
        let vm = ImportViewModel()
        vm.excludedExtensionsRaw = "jpg"
        vm.excludedCameraModelsRaw = "iPhone"
        vm.dateFrom = Date(timeIntervalSince1970: 1000)
        vm.dateTo = Date(timeIntervalSince1970: 2000)

        let filter = vm.activeFilter
        #expect(filter.excludedExtensions == ["jpg"])
        #expect(filter.excludedCameraModels == ["iPhone"])
        #expect(filter.dateFrom != nil)
        #expect(filter.dateTo != nil)
    }

    // MARK: - Toggle functions

    @Test func toggleExtensionAdds() {
        let vm = ImportViewModel()
        vm.toggleExtension("jpg")
        #expect(vm.excludedExtensions.contains("jpg"))
    }

    @Test func toggleExtensionRemoves() {
        let vm = ImportViewModel()
        vm.excludedExtensionsRaw = "jpg"
        vm.toggleExtension("jpg")
        #expect(!vm.excludedExtensions.contains("jpg"))
    }

    @Test func toggleCameraModelAdds() {
        let vm = ImportViewModel()
        vm.toggleCameraModel("Canon EOS R6")
        #expect(vm.excludedCameraModels.contains("Canon EOS R6"))
    }

    @Test func toggleCameraModelRemoves() {
        let vm = ImportViewModel()
        vm.excludedCameraModelsRaw = "Canon EOS R6"
        vm.toggleCameraModel("Canon EOS R6")
        #expect(!vm.excludedCameraModels.contains("Canon EOS R6"))
    }

    // MARK: - Photos library detection

    @Test func detectsPhotosLibrarySource() {
        let vm = ImportViewModel()
        vm.sourcePath = "/Volumes/BAR/Photos.photoslibrary/originals"
        #expect(vm.isPhotosLibrarySource == true)
    }

    @Test func nonPhotosLibrarySource() {
        let vm = ImportViewModel()
        vm.sourcePath = "/Volumes/SD_CARD/DCIM"
        #expect(vm.isPhotosLibrarySource == false)
    }

    // MARK: - Filtered counts

    @Test func filteredCountsWithNoPreview() {
        let vm = ImportViewModel()
        let counts = vm.filteredCounts
        #expect(counts.total == 0)
        #expect(counts.new == 0)
        #expect(counts.duplicates == 0)
    }

    @Test func filteredCountsWithPreview() {
        let vm = ImportViewModel()
        let files = [
            PreviewFile(url: URL(fileURLWithPath: "/a.cr3"), filename: "a.cr3", ext: "cr3", size: 100, date: Date(), dateSource: .exif, cameraModel: nil, isDuplicate: false),
            PreviewFile(url: URL(fileURLWithPath: "/b.jpg"), filename: "b.jpg", ext: "jpg", size: 50, date: Date(), dateSource: .exif, cameraModel: nil, isDuplicate: false),
            PreviewFile(url: URL(fileURLWithPath: "/c.cr3"), filename: "c.cr3", ext: "cr3", size: 100, date: Date(), dateSource: .exif, cameraModel: nil, isDuplicate: true),
        ]
        vm.previewResult = PreviewResult(files: files)

        let counts = vm.filteredCounts
        #expect(counts.total == 3)
        #expect(counts.new == 2)
        #expect(counts.duplicates == 1)
    }

    @Test func filteredCountsWithExtensionFilter() {
        let vm = ImportViewModel()
        vm.excludedExtensionsRaw = "jpg"
        let files = [
            PreviewFile(url: URL(fileURLWithPath: "/a.cr3"), filename: "a.cr3", ext: "cr3", size: 100, date: Date(), dateSource: .exif, cameraModel: nil, isDuplicate: false),
            PreviewFile(url: URL(fileURLWithPath: "/b.jpg"), filename: "b.jpg", ext: "jpg", size: 50, date: Date(), dateSource: .exif, cameraModel: nil, isDuplicate: false),
        ]
        vm.previewResult = PreviewResult(files: files)

        let counts = vm.filteredCounts
        #expect(counts.total == 1)
        #expect(counts.new == 1)
    }
}
