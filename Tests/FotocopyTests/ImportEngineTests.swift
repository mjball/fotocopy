import Testing
import Foundation
import ImageIO
import CoreGraphics
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

    // MARK: - importFiles

    @Test func importCopyMode() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "photo.jpg", content: "image data")
        let files = [src.appendingPathComponent("photo.jpg")]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
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
        let files = [src.appendingPathComponent("photo.jpg")]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .move,
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
        let files = [src.appendingPathComponent("photo.jpg")]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let imported = try findImportedFiles(in: dst)
        #expect(imported.count == 1)

        let relativePath = imported[0].path.replacingOccurrences(of: dst.path + "/", with: "")
        let components = relativePath.split(separator: "/")
        #expect(components.count == 4) // YYYY/MM/DD/filename
    }

    @Test func importSkipsDuplicates() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let content = "image data"
        try createFile(src, name: "photo.jpg", content: content)

        let sub = dst.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "photo.jpg", content: content)

        let files = [src.appendingPathComponent("photo.jpg")]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let skipped = await progress.duplicatesSkipped
        #expect(skipped == 1)
    }

    @Test func importHandlesFilenameCollision() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "photo.jpg", content: "new image")
        let files = [src.appendingPathComponent("photo.jpg")]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let firstImported = try findImportedFiles(in: dst)
        #expect(firstImported.count == 1)
        let dateDir = firstImported[0].deletingLastPathComponent()

        try Data("different image".utf8).write(to: src.appendingPathComponent("photo.jpg"))
        let checker2 = DuplicateChecker()
        try await checker2.buildIndex(at: dst)
        let progress2 = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
            duplicateChecker: checker2, progress: progress2
        )

        let allFiles = try FileManager.default.contentsOfDirectory(
            at: dateDir, includingPropertiesForKeys: nil
        )
        #expect(allFiles.count == 2)
        let names = Set(allFiles.map { $0.lastPathComponent })
        #expect(names.contains("photo.jpg"))
        #expect(names.contains("photo_1.jpg"))
    }

    @Test func importMultipleCollisions() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let files = [src.appendingPathComponent("photo.jpg")]
        let engine = ImportEngine()

        for i in 0..<3 {
            // Each version has different size so it's not detected as a duplicate
            let content = String(repeating: "x", count: 100 + i)
            try Data(content.utf8).write(to: src.appendingPathComponent("photo.jpg"))
            let checker = DuplicateChecker()
            try await checker.buildIndex(at: dst)
            let progress = await ImportProgress()
            await engine.importFilesForTest(
                files: files, destination: dst, mode: .copy,
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
        let files = [src.appendingPathComponent("noexif.jpg")]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
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
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: [], destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let processed = await progress.processedFiles
        #expect(processed == 0)
    }

    @Test func importMarksInChecker() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let content = "image data"
        try createFile(src, name: "photo.jpg", content: content)
        let files = [src.appendingPathComponent("photo.jpg")]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress
        )

        let isDup = await checker.isDuplicate(filename: "photo.jpg", size: content.utf8.count)
        #expect(isDup == true)
    }

    @Test func importWithEXIFDate() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let file = src.appendingPathComponent("exif.jpg")
        try createMinimalJPEGWithEXIF(at: file, dateString: "2023:12:25 10:30:00")
        let files = [file]

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)
        let progress = await ImportProgress()

        await engine.importFilesForTest(
            files: files, destination: dst, mode: .copy,
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
        try await checker.buildIndex(at: dst)

        let preview = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.totalFiles == 2)
        #expect(preview.newFileCount == 2)
        #expect(preview.duplicateCount == 0)
    }

    @Test func previewDetectsDuplicates() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let content = "same content"
        try createFile(src, name: "photo.jpg", content: content)
        try createFile(src, name: "unique.jpg", content: "different")

        let sub = dst.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "photo.jpg", content: content)

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)

        let preview = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.totalFiles == 2)
        #expect(preview.duplicateCount == 1)
        #expect(preview.newFileCount == 1)
    }

    @Test func previewEmptySource() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)

        let preview = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.totalFiles == 0)
        #expect(preview.duplicateCount == 0)
        #expect(preview.newFileCount == 0)
    }

    @Test func previewAllDuplicates() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        try createFile(src, name: "a.jpg", content: "aaa")
        try createFile(src, name: "b.jpg", content: "bbb")
        try createFile(dst, name: "a.jpg", content: "aaa")
        try createFile(dst, name: "b.jpg", content: "bbb")

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)

        let preview = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.totalFiles == 2)
        #expect(preview.duplicateCount == 2)
        #expect(preview.newFileCount == 0)
    }

    @Test func importWithPreviewSkipsDuplicates() async throws {
        let src = try makeTempDir()
        let dst = try makeTempDir()
        defer { cleanup(src); cleanup(dst) }

        let dupContent = "duplicate"
        try createFile(src, name: "dup.jpg", content: dupContent)
        try createFile(src, name: "new.jpg", content: "fresh file")

        let sub = dst.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try createFile(sub, name: "dup.jpg", content: dupContent)

        let engine = ImportEngine()
        let checker = DuplicateChecker()
        try await checker.buildIndex(at: dst)

        let preview = try await engine.previewImport(source: src, duplicateChecker: checker)
        #expect(preview.duplicateCount == 1)

        let progress = await ImportProgress()
        try? await engine.importFiles(
            files: preview.files, destination: dst, mode: .copy,
            duplicateChecker: checker, progress: progress,
            previewResult: preview
        )

        let skipped = await progress.duplicatesSkipped
        let processed = await progress.processedFiles
        #expect(skipped == 1)
        #expect(processed == 2)

        let allImported = try findImportedFiles(in: dst)
        let names = Set(allImported.map { $0.lastPathComponent })
        #expect(names.contains("new.jpg"))
        #expect(names.contains("dup.jpg")) // the original in existing/
    }

    // MARK: - Helpers

    private func findImportedFiles(in dir: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            files.append(fileURL)
        }
        return files
    }

    private func createMinimalJPEGWithEXIF(at url: URL, dateString: String) throws {
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

        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateString
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 3)
        }
    }
}

extension ImportEngine {
    func importFilesForTest(
        files: [URL],
        destination: URL,
        mode: TransferMode,
        duplicateChecker: DuplicateChecker,
        progress: ImportProgress
    ) async {
        try? await importFiles(
            files: files, destination: destination, mode: mode,
            duplicateChecker: duplicateChecker, progress: progress
        )
    }
}
