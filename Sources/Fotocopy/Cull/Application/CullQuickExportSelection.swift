import Foundation

/// Pure selection policy for Quick Export. Views decide whether a click is an
/// extending command-click; the application state never reads a live AppKit
/// event, which keeps this behavior deterministic and directly testable.
struct CullQuickExportSelection: Equatable {
    private(set) var urls: Set<URL> = []

    mutating func select(_ url: URL, extendingSelection: Bool) {
        guard extendingSelection else {
            urls = [url]
            return
        }
        if !urls.insert(url).inserted {
            urls.remove(url)
        }
    }

    mutating func reset(to url: URL?) {
        urls = Set(url.map { [$0] } ?? [])
    }

    mutating func clear() {
        urls.removeAll()
    }

    mutating func rewrite(using replacements: [URL: URL]) {
        urls = Set(urls.map { replacements[$0] ?? $0 })
    }

    func selectedURLs(from frames: [CullPhoto], fallback: URL?) -> [URL] {
        let selected = urls.isEmpty ? Set(fallback.map { [$0] } ?? []) : urls
        return frames.map(\.url).filter(selected.contains)
    }
}
