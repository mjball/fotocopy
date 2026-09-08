import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullQuickExportSelectionTests {
    @Test func normalClickReplacesSelectionAndCommandClickTogglesFrames() {
        let first = URL(fileURLWithPath: "/tmp/IMG_0001.CR3")
        let second = URL(fileURLWithPath: "/tmp/IMG_0002.CR3")
        var selection = CullQuickExportSelection()

        selection.select(first, extendingSelection: false)
        selection.select(second, extendingSelection: true)
        #expect(selection.urls == [first, second])

        selection.select(first, extendingSelection: true)
        #expect(selection.urls == [second])

        selection.select(first, extendingSelection: false)
        #expect(selection.urls == [first])
    }

    @Test func selectionUsesFocusedFrameAsFallbackAndTracksCullMoves() {
        let first = URL(fileURLWithPath: "/tmp/IMG_0001.CR3")
        let second = URL(fileURLWithPath: "/tmp/IMG_0002.CR3")
        let movedFirst = URL(fileURLWithPath: "/tmp/Keeps/IMG_0001.CR3")
        let frames = [photo(at: first), photo(at: second)]
        var selection = CullQuickExportSelection()

        #expect(selection.selectedURLs(from: frames, fallback: second) == [second])

        selection.select(first, extendingSelection: false)
        selection.rewrite(using: [first: movedFirst])
        let movedFrames = [photo(at: movedFirst), photo(at: second)]
        #expect(selection.selectedURLs(from: movedFrames, fallback: second) == [movedFirst])
    }

    private func photo(at url: URL) -> CullPhoto {
        CullPhoto(
            url: url,
            filename: url.lastPathComponent,
            captureDate: nil,
            dateSource: nil,
            sequenceNumber: nil
        )
    }
}
