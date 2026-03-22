import Foundation
import SQLite3

func createMockPhotosDB(at path: String, entries: [(String, String)]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else {
        throw NSError(domain: "test", code: 1)
    }
    defer { sqlite3_close(db) }

    let sql = """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZFILENAME VARCHAR);
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZORIGINALFILENAME VARCHAR);
        """
    sqlite3_exec(db, sql, nil, nil, nil)

    for (i, entry) in entries.enumerated() {
        let pk = i + 1
        sqlite3_exec(db, "INSERT INTO ZASSET (Z_PK, ZFILENAME) VALUES (\(pk), '\(entry.0)');", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO ZADDITIONALASSETATTRIBUTES (Z_PK, ZASSET, ZORIGINALFILENAME) VALUES (\(pk), \(pk), '\(entry.1)');", nil, nil, nil)
    }
}
