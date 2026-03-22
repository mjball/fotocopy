import Testing
import Foundation
import SQLite3
@testable import Fotocopy

@Suite
struct PhotosLibraryResolverTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func detectsPhotosLibraryRoot() {
        let url = URL(fileURLWithPath: "/Volumes/BAR/My Photos.photoslibrary/originals/0/file.cr3")
        let root = PhotosLibraryResolver.findPhotosLibraryRoot(from: url)
        #expect(root?.path == "/Volumes/BAR/My Photos.photoslibrary")
    }

    @Test func returnsNilForNonPhotosPath() {
        let url = URL(fileURLWithPath: "/Volumes/SD_CARD/DCIM/100CANON/IMG_001.cr3")
        let root = PhotosLibraryResolver.findPhotosLibraryRoot(from: url)
        #expect(root == nil)
    }

    @Test func resolveReturnsNilForNonPhotosPath() {
        let url = URL(fileURLWithPath: "/tmp/some/folder")
        let resolver = PhotosLibraryResolver.resolve(for: url)
        #expect(resolver == nil)
    }

    @Test func resolveWithMockDatabase() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let libraryRoot = dir.appendingPathComponent("Test.photoslibrary")
        let dbDir = libraryRoot.appendingPathComponent("database")
        let originalsDir = libraryRoot.appendingPathComponent("originals/0")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)

        let dbPath = dbDir.appendingPathComponent("Photos.sqlite").path
        try createMockPhotosDB(at: dbPath, entries: [
            ("AAAA-BBBB-CCCC.cr3", "IMG_0001.CR3"),
            ("DDDD-EEEE-FFFF.jpg", "DSC_1234.JPG"),
        ])

        let resolver = PhotosLibraryResolver.resolve(for: originalsDir)
        #expect(resolver != nil)
        #expect(resolver?.originalFilename(for: "AAAA-BBBB-CCCC.cr3") == "IMG_0001.CR3")
        #expect(resolver?.originalFilename(for: "DDDD-EEEE-FFFF.jpg") == "DSC_1234.JPG")
    }

    @Test func originalFilenamePassesThroughUnknown() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let libraryRoot = dir.appendingPathComponent("Test.photoslibrary")
        let dbDir = libraryRoot.appendingPathComponent("database")
        let originalsDir = libraryRoot.appendingPathComponent("originals/0")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)

        let dbPath = dbDir.appendingPathComponent("Photos.sqlite").path
        try createMockPhotosDB(at: dbPath, entries: [
            ("AAAA-BBBB-CCCC.cr3", "IMG_0001.CR3"),
        ])

        let resolver = PhotosLibraryResolver.resolve(for: originalsDir)!
        #expect(resolver.originalFilename(for: "UNKNOWN-UUID.cr3") == "UNKNOWN-UUID.cr3")
    }

}
