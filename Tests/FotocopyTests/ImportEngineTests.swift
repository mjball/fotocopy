import Testing
import Foundation
import ImageIO
import CoreGraphics
import SQLite3
@testable import Fotocopy

@Suite
struct ImportEngineTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func createFile(_ dir: URL, name: String, content: String = "test") throws {
        try Data(content.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func registerImported(
        checker: DuplicateChecker,
        relativePath: String,
        filename: String,
        size: Int,
        sourceBucket: String = DestinationManifest.rootBucket
    ) async throws {
        try await checker.markImported(
            filename: filename,
            size: size,
            sourceBucket: sourceBucket,
            destinationRelativePath: relativePath,
            destinationSize: size
        )
    }

    // MARK: - discoverFiles

    @Test func discoverSupportedExtensions() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let supported = ["photo.jpg", "image.jpeg", "shot.heic", "raw.cr2", "raw.cr3",
                         "raw.nef", "raw.arw", "raw.dng", "raw.raf", "raw.orf", "raw.rw2",
                         "video.mov", "clip.mp4", "movie.m4v", "pic.heif"]
        for name in supported {
            try createFile(dir, name: name)
        }

        let engine = ImportEngine()
        let files = try await engine.discoverFiles(in: dir)
        #expect(files.count == supported.count)
    }

    @Test func discoverIgnoresUnsupported() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try createFile(dir, name: "readme.txt")
        try createFile(dir, name: "document.pdf")
        try createFile(dir, name: "spreadsheet.xlsx")
        try createFile(dir, name: "photo.jpg")

        let engine = ImportEngine()
        let files = try await engine.discoverFiles(in: dir)
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent == "photo.jpg")
    }

    @Test func discoverCaseInsensitive() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try createFile(dir, name: "PHOTO.JPG")
        try createFile(dir, name: "Image.HEIC")
        try createFile(dir, name: "Video.MOV")

        let engine = ImportEngine()
        let files = try await engine.discoverFiles(in: dir)
        #expect(files.count == 3)
    }

    @Test func discoverEmptyDirectory() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let engine = ImportEngine()
        let files = try await engine.discoverFiles(in: dir)
        #expect(files.isEmpty)
    }

    @Test func discoverNestedDirectories() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let sub = dir.appendingPathComponent("DCIM").appendingPathComponent("100CANON")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "IMG_001.cr2")
        try createFile(dir, name: "photo.jpg")

        let engine = ImportEngine()
        let files = try await engine.discoverFiles(in: dir)
        #expect(files.count == 2)
    }

    @Test func discoverSkipsHiddenFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try createFile(dir, name: ".hidden_photo.jpg")
        try createFile(dir, name: "visible.jpg")

        let engine = ImportEngine()
        let files = try await engine.discoverFiles(in: dir)
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent == "visible.jpg")
    }

    @Test func discoverSkipsCacheDirectories() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = dir.appendingPathComponent("Cache")
        let thumbnails = dir.appendingPathComponent("Thumbnails")
        let derivatives = dir.appendingPathComponent("Derivatives")
        let resources = dir.appendingPathComponent("resources")
        let originals = dir.appendingPathComponent("originals")
        for sub in [cache, thumbnails, derivatives, resources, originals] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try createFile(sub, name: "photo.jpg")
        }

        let engine = ImportEngine()
        let files = try await engine.discoverFiles(in: dir)
        #expect(files.count == 1)
        #expect(files[0].path.contains("originals"))
    }

    // MARK: - importFiles

    @Test func importCopyMode() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "photo.jpg", content: "image data")
        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("photo.jpg").path))
        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)
    }

    @Test func importMoveMode() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "photo.jpg", content: "image data")
        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .move,
            duplicateChecker: checker, progress: progress
        )

        #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent("photo.jpg").path))
        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)
    }

    @Test func importCreatesDateDirectoryStructure() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "photo.jpg", content: "image data")
        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)

        let dstResolved = dst.standardizedFileURL.path
        let relativePath = imported[0].standardizedFileURL.path
            .replacingOccurrences(of: dstResolved + "/", with: "")
        let components = relativePath.split(separator: "/")
        #expect(components.count == 4) // YYYY/MM/DD/filename
    }

    @Test func importSkipsDuplicates() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let content = "image data"
        try createFile(src, name: "photo.jpg", content: content)

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dst) == .ready)

        let sub = dst.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "photo.jpg", content: content)
        try await registerImported(
            checker: checker,
            relativePath: "existing/photo.jpg",
            filename: "photo.jpg",
            size: content.utf8.count
        )

        let engine = ImportEngine()
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let skipped = await progress.duplicatesSkipped
        #expect(skipped == 1)
    }

    @Test func importTreatsSameFilenameDifferentSourceFolderAsNew() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let sourceRoot = src.appendingPathComponent("DCIM")
        let bucket100 = sourceRoot.appendingPathComponent("100EOSR6")
        let bucket101 = sourceRoot.appendingPathComponent("101EOSR6")
        try FileManager.default.createDirectory(at: bucket100, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bucket101, withIntermediateDirectories: true)

        let content = "same content"
        try createFile(bucket100, name: "IMG_0001.CR3", content: content)
        try createFile(bucket101, name: "IMG_0001.CR3", content: content)

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dst) == .ready)

        let (_, preview) = try await engine.previewImport(source: sourceRoot, duplicateChecker: checker)
        let counts = preview.filteredCounts(by: ImportFilter())

        #expect(counts.total == 2)
        #expect(counts.new == 2)
        #expect(counts.duplicates == 0)
        #expect(Set(preview.files.map(\.sourceBucket)) == ["100", "101"])
    }

    @Test func importHandlesFilenameCollision() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "photo.jpg", content: "new image")
        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview1) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress1 = await ImportProgress()
        try await engine.importFiles(
            files: preview1.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress1
        )

        let firstImported = try findImportedFiles(in: dst)
        let dateDir = firstImported[0].deletingLastPathComponent()

        try Data("different image".utf8).write(to: src.appendingPathComponent("photo.jpg"))
        let checker2 = DuplicateChecker()
        _ = try await checker2.buildIndex(at: dst)
        let (_, preview2) = try await engine.previewImport(source: src, duplicateChecker: checker2)
        let progress2 = await ImportProgress()
        try await engine.importFiles(
            files: preview2.files, destination: dst, mode: .copy,
            duplicateChecker: checker2, progress: progress2
        )

        let allFiles = try FileManager.default.contentsOfDirectory(at: dateDir, includingPropertiesForKeys: nil)
        #expect(allFiles.count == 2)
        let names = Set(allFiles.map { $0.lastPathComponent })
        #expect(names.contains("photo.jpg"))
        #expect(names.contains("photo_1.jpg"))
    }

    @Test func importMultipleCollisions() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let engine = ImportEngine()

        for i in 0..<3 {
            let content = String(repeating: "x", count: 100 + i)
            try Data(content.utf8).write(to: src.appendingPathComponent("photo.jpg"))
            let checker = DuplicateChecker()
            _ = try await checker.buildIndex(at: dst)
            let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
            let progress = await ImportProgress()
            try await engine.importFiles(
                files: preview.files, destination: dst, mode: .copy,
                duplicateChecker: checker, progress: progress
            )
        }

        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 3)
        let names = Set(imported.map { $0.lastPathComponent })
        #expect(names.contains("photo.jpg"))
        #expect(names.contains("photo_1.jpg"))
        #expect(names.contains("photo_2.jpg"))
    }

    @Test func importTracksFallbackDateFiles() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "noexif.jpg", content: "plain text, no EXIF")
        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let fallbacks = await progress.fallbackDateFiles
        #expect(fallbacks.contains("noexif.jpg"))
    }

    @Test func importEmptyFileList() async throws {
        let dst = try makeTempDir()
        defer { cleanup(dst) }

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: [], destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let processed = await progress.processedFiles
        #expect(processed == 0)
    }

    @Test func importMissingSourceCountsAsFailedTransfer() async throws {
        let dst = try makeTempDir()
        defer { cleanup(dst) }

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()
        await progress.beginImport(totalFiles: 1, totalTransferBytes: 1_024)

        let missing = PreviewFile(
            url: dst.appendingPathComponent("missing.jpg"),
            filename: "missing.jpg",
            ext: "jpg",
            size: 1_024,
            date: Date(),
            dateSource: .exif,
            cameraModel: nil,
            isDuplicate: false
        )

        try await engine.importFiles(
            files: [missing], destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let failed = await progress.failedFiles
        let settled = await progress.settledTransferBytes
        let transferred = await progress.transferredBytes
        let throughput = await progress.throughputBytesPerSecond
        #expect(failed == 1)
        #expect(settled == 1_024)
        #expect(transferred == 0)
        #expect(throughput == nil)
    }

    @Test func importUndatedFileCountsAsFailedTransfer() async throws {
        let dst = try makeTempDir()
        defer { cleanup(dst) }

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()
        await progress.beginImport(totalFiles: 1, totalTransferBytes: 512)

        let undated = PreviewFile(
            url: dst.appendingPathComponent("undated.jpg"),
            filename: "undated.jpg",
            ext: "jpg",
            size: 512,
            date: nil,
            dateSource: nil,
            cameraModel: nil,
            isDuplicate: false
        )

        try await engine.importFiles(
            files: [undated], destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let failed = await progress.failedFiles
        let settled = await progress.settledTransferBytes
        let transferred = await progress.transferredBytes
        #expect(failed == 1)
        #expect(settled == 512)
        #expect(transferred == 0)
    }

    @Test func importMarksInChecker() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let content = "image data"
        try createFile(src, name: "photo.jpg", content: content)
        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let isDup = await checker.isDuplicate(
            filename: "photo.jpg",
            size: content.utf8.count,
            sourceBucket: DestinationManifest.rootBucket
        )
        #expect(isDup == true)
    }

    @Test func importWithEXIFDate() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let file = src.appendingPathComponent("exif.jpg")
        try createMinimalJPEGWithEXIF(at: file, dateString: "2023:12:25 10:30:00")
        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)

        let dstResolved = dst.standardizedFileURL.path
        let relativePath = imported[0].standardizedFileURL.path
            .replacingOccurrences(of: dstResolved + "/", with: "")
        #expect(relativePath.hasPrefix("2023/12/25/"))

        let fallbacks = await progress.fallbackDateFiles
        #expect(fallbacks.isEmpty)
    }

    // MARK: - Preview

    @Test func previewCountsFiles() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "a.jpg", content: "aaa")
        try createFile(src, name: "b.mov", content: "bbb")
        try createFile(src, name: "readme.txt", content: "skip me")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.files.count == 2)
        let counts = preview.filteredCounts(by: ImportFilter())
        #expect(counts.new == 2)
        #expect(counts.duplicates == 0)
    }

    @Test func previewDetectsDuplicates() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let content = "same content"
        try createFile(src, name: "photo.jpg", content: content)
        try createFile(src, name: "unique.jpg", content: "different")

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dst) == .ready)

        let sub = dst.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "photo.jpg", content: content)
        try await registerImported(
            checker: checker,
            relativePath: "existing/photo.jpg",
            filename: "photo.jpg",
            size: content.utf8.count
        )

        let engine = ImportEngine()

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let counts = preview.filteredCounts(by: ImportFilter())
        #expect(counts.total == 2)
        #expect(counts.duplicates == 1)
        #expect(counts.new == 1)
    }

    @Test func previewEmptySource() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.files.isEmpty)
    }

    @Test func previewAllDuplicates() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "a.jpg", content: "aaa")
        try createFile(src, name: "b.jpg", content: "bbb")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dst) == .ready)
        try createFile(dst, name: "a.jpg", content: "aaa")
        try createFile(dst, name: "b.jpg", content: "bbb")
        try await registerImported(
            checker: checker,
            relativePath: "a.jpg",
            filename: "a.jpg",
            size: "aaa".utf8.count
        )
        try await registerImported(
            checker: checker,
            relativePath: "b.jpg",
            filename: "b.jpg",
            size: "bbb".utf8.count
        )

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let counts = preview.filteredCounts(by: ImportFilter())
        #expect(counts.total == 2)
        #expect(counts.duplicates == 2)
        #expect(counts.new == 0)
    }

    @Test func previewExtensionCounts() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "a.jpg", content: "aaa")
        try createFile(src, name: "b.jpg", content: "bbb")
        try createFile(src, name: "c.cr3", content: "ccc")
        try createFile(src, name: "d.mov", content: "ddd")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        let counts = preview.extensionCounts
        #expect(counts["jpg"] == 2)
        #expect(counts["cr3"] == 1)
        #expect(counts["mov"] == 1)
    }

    @Test func previewDateRange() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "a.jpg", content: "aaa")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.dateRange != nil)
    }

    @Test func previewFileCarriesMetadata() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "photo.cr3", content: "raw image data")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.files.count == 1)
        let file = preview.files[0]
        #expect(file.filename == "photo.cr3")
        #expect(file.ext == "cr3")
        #expect(file.size == "raw image data".utf8.count)
        #expect(file.isDuplicate == false)
        #expect(file.date != nil)
    }

    // MARK: - Filter

    @Test func filterByExtension() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "a.jpg", content: "aaa")
        try createFile(src, name: "b.cr3", content: "bbb")
        try createFile(src, name: "c.mov", content: "ccc")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)

        let filter = ImportFilter(excludedExtensions: ["jpg", "mov"])
        let filtered = preview.filtered(by: filter)
        #expect(filtered.count == 1)
        #expect(filtered[0].ext == "cr3")
    }

    @Test func filterByDateRange() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let file1 = src.appendingPathComponent("old.jpg")
        try createMinimalJPEGWithEXIF(at: file1, dateString: "2020:01:15 10:00:00")
        let file2 = src.appendingPathComponent("new.jpg")
        try createMinimalJPEGWithEXIF(at: file2, dateString: "2025:06:15 10:00:00")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.files.count == 2)

        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let cutoff = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let filter = ImportFilter(dateFrom: cutoff)
        let filtered = preview.filtered(by: filter)
        #expect(filtered.count == 1)
        #expect(filtered[0].filename == "new.jpg")
    }

    @Test func filterCombined() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "a.jpg", content: "aaa")
        try createFile(src, name: "b.cr3", content: "bbb")
        try createFile(src, name: "c.mov", content: "ccc")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)

        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)

        let filter = ImportFilter(excludedExtensions: ["jpg"])
        let counts = preview.filteredCounts(by: filter)
        #expect(counts.total == 2)
        #expect(counts.new == 2)
    }

    @Test func filterExcludesFromImport() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "keep.cr3", content: "raw data")
        try createFile(src, name: "skip.jpg", content: "jpeg data")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)

        let filter = ImportFilter(excludedExtensions: ["jpg"])
        let filtered = preview.filtered(by: filter)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: filtered, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)
        #expect(imported[0].lastPathComponent == "keep.cr3")
    }

    // MARK: - Photos Library filename resolution in import

    @Test func importUsesResolvedFilename() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let libraryRoot = dir.appendingPathComponent("Test.photoslibrary")
        let dbDir = libraryRoot.appendingPathComponent("database")
        let originalsDir = libraryRoot.appendingPathComponent("originals/0")
        let dst = dir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let dbPath = dbDir.appendingPathComponent("Photos.sqlite").path
        try createMockPhotosDB(at: dbPath, entries: [
            ("AAAA-BBBB-CCCC.cr3", "BL5A5086.CR3"),
        ])
        try createFile(originalsDir, name: "AAAA-BBBB-CCCC.cr3", content: "raw image data")

        let resolver = PhotosLibraryResolver.resolve(for: originalsDir)
        #expect(resolver != nil)

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(
            source: originalsDir, duplicateChecker: checker, resolver: resolver
        )

        #expect(preview.files.count == 1)
        #expect(preview.files[0].filename == "BL5A5086.CR3")

        let progress = await ImportProgress()
        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)
        #expect(imported[0].lastPathComponent == "BL5A5086.CR3")
    }

    @Test func importResolvedFilenameUsedForDedup() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let libraryRoot = dir.appendingPathComponent("Test.photoslibrary")
        let dbDir = libraryRoot.appendingPathComponent("database")
        let originalsDir = libraryRoot.appendingPathComponent("originals/0")
        let dst = dir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let content = "raw image data"
        let dbPath = dbDir.appendingPathComponent("Photos.sqlite").path
        try createMockPhotosDB(at: dbPath, entries: [
            ("AAAA-BBBB-CCCC.cr3", "BL5A5086.CR3"),
        ])
        try createFile(originalsDir, name: "AAAA-BBBB-CCCC.cr3", content: content)

        let checker = DuplicateChecker()
        #expect(try await checker.buildIndex(at: dst) == .ready)

        let existingSub = dst.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existingSub, withIntermediateDirectories: true)
        try createFile(existingSub, name: "BL5A5086.CR3", content: content)
        try await registerImported(
            checker: checker,
            relativePath: "existing/BL5A5086.CR3",
            filename: "BL5A5086.CR3",
            size: content.utf8.count,
            sourceBucket: DestinationManifest.photosLibraryBucket
        )

        let resolver = PhotosLibraryResolver.resolve(for: originalsDir)
        let engine = ImportEngine()
        let (_, preview) = try await engine.previewImport(
            source: originalsDir, duplicateChecker: checker, resolver: resolver
        )

        #expect(preview.files[0].isDuplicate == true)

        let progress = await ImportProgress()
        try await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let skipped = await progress.duplicatesSkipped
        #expect(skipped == 1)
    }

    // MARK: - Camera model

    @Test func previewReadsCameraModel() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let file = src.appendingPathComponent("canon.jpg")
        try createMinimalJPEGWithEXIF(at: file, dateString: "2024:01:01 00:00:00", cameraModel: "Canon EOS R6 Mark III")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)

        #expect(preview.files[0].cameraModel == "Canon EOS R6 Mark III")
    }

    @Test func previewCameraModelCounts() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createMinimalJPEGWithEXIF(at: src.appendingPathComponent("a.jpg"), dateString: "2024:01:01 00:00:00", cameraModel: "Canon EOS R6")
        try createMinimalJPEGWithEXIF(at: src.appendingPathComponent("b.jpg"), dateString: "2024:01:02 00:00:00", cameraModel: "Canon EOS R6")
        try createMinimalJPEGWithEXIF(at: src.appendingPathComponent("c.jpg"), dateString: "2024:01:03 00:00:00", cameraModel: "iPhone 15 Pro")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)

        let counts = preview.cameraModelCounts
        #expect(counts["Canon EOS R6"] == 2)
        #expect(counts["iPhone 15 Pro"] == 1)
    }

    @Test func filterByCameraModel() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createMinimalJPEGWithEXIF(at: src.appendingPathComponent("a.jpg"), dateString: "2024:01:01 00:00:00", cameraModel: "Canon EOS R6")
        try createMinimalJPEGWithEXIF(at: src.appendingPathComponent("b.jpg"), dateString: "2024:01:02 00:00:00", cameraModel: "iPhone 15 Pro")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)

        let filter = ImportFilter(excludedCameraModels: ["iPhone 15 Pro"])
        let filtered = preview.filtered(by: filter)
        #expect(filtered.count == 1)
        #expect(filtered[0].cameraModel == "Canon EOS R6")
    }

    @Test func filterByCameraModelImport() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createMinimalJPEGWithEXIF(at: src.appendingPathComponent("canon.jpg"), dateString: "2024:01:01 00:00:00", cameraModel: "Canon EOS R6")
        try createMinimalJPEGWithEXIF(at: src.appendingPathComponent("phone.jpg"), dateString: "2024:01:02 00:00:00", cameraModel: "iPhone 15 Pro")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        _ = try await checker.buildIndex(at: dst)
        let (_, preview) = try await engine.previewImport(source: src, duplicateChecker: checker)

        let filter = ImportFilter(excludedCameraModels: ["iPhone 15 Pro"])
        let filtered = preview.filtered(by: filter)
        let progress = await ImportProgress()

        try await engine.importFiles(
            files: filtered, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)
        #expect(imported[0].lastPathComponent == "canon.jpg")
    }

    // MARK: - Helpers

    private func findImportedFiles(in dir: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
            if rv.isDirectory == true, fileURL.lastPathComponent == DestinationManifest.metadataDirectoryName {
                enumerator.skipDescendants()
                continue
            }
            guard rv.isRegularFile == true else { continue }
            files.append(fileURL)
        }
        return files
    }

    private func createMinimalJPEGWithEXIF(at url: URL, dateString: String, cameraModel: String? = nil) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            throw NSError(domain: "test", code: 1)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw NSError(domain: "test", code: 2)
        }

        var props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateString
            ]
        ]
        if let cameraModel {
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFModel: cameraModel
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 3)
        }
    }

}
