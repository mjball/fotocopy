import Foundation
import Testing
@testable import Fotocopy

@Suite
struct CullQuickExportSelectionTests {
    @Test func normalClickReplacesSelectionAndCommandClickTogglesFrames() {
        let first = URL(fileURLWithPath: "/tmp/IMG_0001.CR3")
        let second = URL(fileURLWithPath: "/tmp/IMG_0002.CR3")
        var selection = CullQuickExportSelection()
        let frames = [first, second]

        selection.select(first, in: frames, extendingSelection: false, selectingRange: false)
        selection.select(second, in: frames, extendingSelection: true, selectingRange: false)
        #expect(selection.urls == [first, second])

        selection.select(first, in: frames, extendingSelection: true, selectingRange: false)
        #expect(selection.urls == [second])

        selection.select(first, in: frames, extendingSelection: false, selectingRange: false)
        #expect(selection.urls == [first])
    }

    @Test func shiftClickSelectsAnInclusiveRangeFromThePlainClickAnchor() {
        let frames = urls(count: 5)
        var selection = CullQuickExportSelection()

        selection.select(frames[1], in: frames, extendingSelection: false, selectingRange: false)
        selection.select(frames[4], in: frames, extendingSelection: false, selectingRange: true)

        #expect(selection.urls == Set(frames[1...4]))
    }

    @Test func shiftClickSelectsAReverseInclusiveRange() {
        let frames = urls(count: 5)
        var selection = CullQuickExportSelection()

        selection.select(frames[4], in: frames, extendingSelection: false, selectingRange: false)
        selection.select(frames[1], in: frames, extendingSelection: false, selectingRange: true)

        #expect(selection.urls == Set(frames[1...4]))
    }

    @Test func commandShiftClickAddsItsRangeToTheExistingSelection() {
        let frames = urls(count: 6)
        var selection = CullQuickExportSelection()

        selection.select(frames[1], in: frames, extendingSelection: false, selectingRange: false)
        selection.select(frames[5], in: frames, extendingSelection: true, selectingRange: true)
        selection.select(frames[0], in: frames, extendingSelection: true, selectingRange: false)

        #expect(selection.urls == Set(frames))
    }

    @Test func selectionUsesFocusedFrameAsFallbackAndTracksCullMoves() {
        let first = URL(fileURLWithPath: "/tmp/IMG_0001.CR3")
        let second = URL(fileURLWithPath: "/tmp/IMG_0002.CR3")
        let movedFirst = URL(fileURLWithPath: "/tmp/Keeps/IMG_0001.CR3")
        let frames = [photo(at: first), photo(at: second)]
        var selection = CullQuickExportSelection()

        #expect(selection.selectedURLs(from: frames, fallback: second) == [second])

        selection.select(first, in: [first, second], extendingSelection: false, selectingRange: false)
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

    private func urls(count: Int) -> [URL] {
        (1...count).map { number in
            URL(fileURLWithPath: "/tmp/IMG_\(String(format: "%04d", number)).CR3")
        }
    }
}
