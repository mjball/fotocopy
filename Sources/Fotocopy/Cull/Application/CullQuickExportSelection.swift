import Foundation

/// Pure selection policy for Quick Export. Views supply the modifier state and
/// ordered frames; the application state never reads a live AppKit event,
/// which keeps this behavior deterministic and directly testable.
struct CullQuickExportSelection: Equatable {
    private(set) var urls: Set<URL> = []
    private var rangeAnchor: URL?

    mutating func select(
        _ url: URL,
        in orderedURLs: [URL],
        extendingSelection: Bool,
        selectingRange: Bool
    ) {
        if selectingRange, let rangeAnchor,
           let anchorIndex = orderedURLs.firstIndex(of: rangeAnchor),
           let selectedIndex = orderedURLs.firstIndex(of: url) {
            let range = Set(orderedURLs[min(anchorIndex, selectedIndex)...max(anchorIndex, selectedIndex)])
            if extendingSelection {
                urls.formUnion(range)
            } else {
                urls = range
            }
            return
        }

        guard extendingSelection else {
            urls = [url]
            rangeAnchor = url
            return
        }

        if !urls.insert(url).inserted {
            urls.remove(url)
        }
    }

    mutating func reset(to url: URL?) {
        urls = Set(url.map { [$0] } ?? [])
        rangeAnchor = url
    }

    mutating func clear() {
        urls.removeAll()
        rangeAnchor = nil
    }

    mutating func rewrite(using replacements: [URL: URL]) {
        urls = Set(urls.map { replacements[$0] ?? $0 })
        rangeAnchor = rangeAnchor.map { replacements[$0] ?? $0 }
    }

    func selectedURLs(from frames: [CullPhoto], fallback: URL?) -> [URL] {
        let selected = urls.isEmpty ? Set(fallback.map { [$0] } ?? []) : urls
        return frames.map(\.url).filter(selected.contains)
    }
}
