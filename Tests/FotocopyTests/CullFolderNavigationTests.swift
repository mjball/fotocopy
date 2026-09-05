import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullFolderNavigationTests {
    private func makeTempDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-cull-folder-navigation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func dateFolder(_ root: URL, _ date: String) -> URL {
        let parts = date.split(separator: "/")
        return parts.reduce(root) { folder, part in
            folder.appendingPathComponent(String(part), isDirectory: true)
        }
    }

    private func createCR3(in folder: URL, name: String = "IMG_0001.CR3") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appendingPathComponent(name))
    }

    @Test func navigatesChronologicallyAcrossReviewableDateFolders() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = dateFolder(root, "2026/02/28")
        let current = dateFolder(root, "2026/03/01")
        let next = dateFolder(root, "2026/03/02")
        try createCR3(in: first)
        try createCR3(in: current.appendingPathComponent("Keeps", isDirectory: true))
        try createCR3(in: next.appendingPathComponent("Rejects", isDirectory: true))

        let folders = CullFolderNavigation.cullFolders(in: root)
        #expect(folders == [first, current, next].map(\.standardizedFileURL))

        let neighbors = try #require(CullFolderNavigation.neighbors(of: current, in: root))
        #expect(neighbors.previous == first.standardizedFileURL)
        #expect(neighbors.next == next.standardizedFileURL)
        #expect(CullFolderNavigation.neighbors(of: first, in: root)?.previous == nil)
        #expect(CullFolderNavigation.neighbors(of: next, in: root)?.next == nil)
    }

    @Test func ignoresInvalidEmptyAndSymlinkedFolders() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = dateFolder(root, "2026/08/22")
        let empty = dateFolder(root, "2026/08/23")
        let invalidDate = dateFolder(root, "2026/02/30")
        let nonDate = root.appendingPathComponent("Exports", isDirectory: true)
        try createCR3(in: valid)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try createCR3(in: invalidDate)
        try createCR3(in: nonDate)

        let linked = dateFolder(root, "2026/08/24")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: valid)

        #expect(CullFolderNavigation.cullFolders(in: root) == [valid.standardizedFileURL])
        #expect(CullFolderNavigation.neighbors(of: empty, in: root) == nil)
    }

    @Test func infersTheLibraryRootOnlyForDateFolders() {
        let day = URL(fileURLWithPath: "/Volumes/Photos/Fotocopy/2026/09/05")
        #expect(
            CullFolderNavigation.libraryRoot(containing: day)?.standardizedFileURL
                == URL(fileURLWithPath: "/Volumes/Photos/Fotocopy", isDirectory: true).standardizedFileURL
        )
        #expect(CullFolderNavigation.libraryRoot(containing: URL(fileURLWithPath: "/Volumes/Photos/Exports")) == nil)
    }
}
