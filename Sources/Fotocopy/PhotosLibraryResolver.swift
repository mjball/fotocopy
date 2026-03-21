import Foundation
import SQLite3

struct PhotosLibraryResolver: Sendable {
    let filenameMap: [String: String]

    static func resolve(for sourcePath: URL) -> PhotosLibraryResolver? {
        guard let libraryRoot = findPhotosLibraryRoot(from: sourcePath) else { return nil }
        let dbPath = libraryRoot.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        guard let map = loadFilenameMap(dbPath: dbPath) else { return nil }
        return PhotosLibraryResolver(filenameMap: map)
    }

    func originalFilename(for uuidFilename: String) -> String {
        filenameMap[uuidFilename] ?? uuidFilename
    }

    static func findPhotosLibraryRoot(from url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "photoslibrary" {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func loadFilenameMap(dbPath: String) -> [String: String]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT a.ZFILENAME, aa.ZORIGINALFILENAME
            FROM ZASSET a
            JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            WHERE aa.ZORIGINALFILENAME IS NOT NULL
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var map: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuidPtr = sqlite3_column_text(stmt, 0),
                  let origPtr = sqlite3_column_text(stmt, 1) else { continue }
            let uuidName = String(cString: uuidPtr)
            let origName = String(cString: origPtr)
            map[uuidName] = origName
        }

        return map.isEmpty ? nil : map
    }
}
