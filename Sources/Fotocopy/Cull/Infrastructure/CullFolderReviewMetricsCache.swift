import Foundation

/// A disposable application cache for expensive burst-shape analysis. It is
/// deliberately separate from Fotocopy's destination manifest because no
/// correctness or file-operation decision may depend on this data.
actor CullFolderReviewMetricsCache {
    private struct Document: Codable {
        let version: Int
        var entries: [String: CullFolderReviewMetrics]
    }

    private static let schemaVersion = 1
    private static let maximumEntryCount = 1_000

    private let cacheURL: URL
    private var entries: [String: CullFolderReviewMetrics]?

    init(cacheURL: URL? = nil, fileManager: FileManager = .default) {
        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.cacheURL = cacheRoot
                .appendingPathComponent("Fotocopy", isDirectory: true)
                .appendingPathComponent("cull-folder-review-metrics.json")
        }
    }

    func validMetrics(
        for summaries: [CullFolderReviewSummary],
        libraryRootURL: URL
    ) -> [URL: CullFolderReviewMetrics] {
        loadIfNeeded()
        var result: [URL: CullFolderReviewMetrics] = [:]
        for summary in summaries {
            let key = cacheKey(libraryRootURL: libraryRootURL, folderURL: summary.folderURL)
            guard let metrics = entries?[key],
                  metrics.inventorySignature == summary.inventorySignature else {
                continue
            }
            result[summary.folderURL] = metrics
        }
        return result
    }

    func store(
        _ metrics: CullFolderReviewMetrics,
        libraryRootURL: URL,
        folderURL: URL
    ) {
        loadIfNeeded()
        entries?[cacheKey(libraryRootURL: libraryRootURL, folderURL: folderURL)] = metrics
        pruneIfNeeded()
        persist()
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        guard let data = try? Data(contentsOf: cacheURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Self.schemaVersion else {
            entries = [:]
            return
        }
        entries = document.entries
    }

    private func pruneIfNeeded() {
        guard let entries, entries.count > Self.maximumEntryCount else { return }
        self.entries = Dictionary(
            uniqueKeysWithValues: entries
                .sorted { $0.value.calculatedAt > $1.value.calculatedAt }
                .prefix(Self.maximumEntryCount)
                .map { ($0.key, $0.value) }
        )
    }

    private func persist() {
        guard let entries else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let document = Document(version: Self.schemaVersion, entries: entries)
            let data = try JSONEncoder().encode(document)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Ranking gracefully falls back to shallow folder counts.
        }
    }

    private func cacheKey(libraryRootURL: URL, folderURL: URL) -> String {
        "\(libraryRootURL.standardizedFileURL.path)\n\(folderURL.standardizedFileURL.path)"
    }
}
