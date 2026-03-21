import Foundation

actor DuplicateChecker {
    private var existing: Set<String> = []

    func buildIndex(at destinationURL: URL) throws {
        existing.removeAll()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: destinationURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  resourceValues.isRegularFile == true,
                  let size = resourceValues.fileSize else { continue }
            let key = makeKey(filename: fileURL.lastPathComponent, size: size)
            existing.insert(key)
        }
    }

    func isDuplicate(filename: String, size: Int) -> Bool {
        existing.contains(makeKey(filename: filename, size: size))
    }

    func markImported(filename: String, size: Int) {
        existing.insert(makeKey(filename: filename, size: size))
    }

    private func makeKey(filename: String, size: Int) -> String {
        "\(filename):\(size)"
    }
}
