import CoreGraphics
import Foundation

/// An AF rectangle recorded by a Canon camera. This is intentionally named a
/// target rather than an eye: Canon's metadata records the active AF area, and
/// eye detection being enabled does not guarantee that the rectangle denotes a
/// single, semantically identified eye.
struct CameraAFTarget: Sendable, Hashable {
    enum State: Sendable, Hashable {
        case focused
        case selected

        var displayName: String {
            switch self {
            case .focused: return "Focused"
            case .selected: return "Selected"
            }
        }
    }

    let center: CullInspectionPoint
    let width: Double
    let height: Double
    let state: State

    /// A normalized top-left-origin rectangle, suitable for the SwiftUI image
    /// preview. Canon records AF coordinates relative to the image centre with
    /// positive Y upwards; the reader converts that convention before creating
    /// this value.
    var normalizedRect: CGRect {
        let unclampedMinX = center.x - width / 2
        let unclampedMinY = center.y - height / 2
        let minX = min(max(unclampedMinX, 0), 1)
        let minY = min(max(unclampedMinY, 0), 1)
        let maxX = min(max(center.x + width / 2, 0), 1)
        let maxY = min(max(center.y + height / 2, 0), 1)
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }
}

/// Minimal, defensive CR3 Canon AF Info 2 reader.
///
/// A CR3 stores Canon's MakerNote in a `CMT3` ISO-BMFF box near the file
/// header. Rather than decode an entire raw file or take a runtime dependency
/// on a command-line metadata tool, this reader reads at most the first MiB,
/// locates that TIFF payload, and interprets just MakerNote tag 0x0026.
enum CanonAFMetadataReader {
    private static let headerReadLimit = 1_024 * 1_024
    private static let canonAFInfo2Tag: UInt16 = 0x0026

    static func readTarget(from url: URL) -> CameraAFTarget? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: headerReadLimit) else {
            return nil
        }
        return target(from: header)
    }

    /// Exposed internally so the binary layout can be covered by a compact,
    /// synthetic fixture without requiring a large CR3 in the test bundle.
    static func target(from data: Data) -> CameraAFTarget? {
        guard let tiffOffset = cmt3TIFFOffset(in: data),
              let byteOrder = TIFFByteOrder(at: tiffOffset, in: data),
              readUInt16(in: data, at: tiffOffset + 2, byteOrder: byteOrder) == 42,
              let firstIFDOffset = readUInt32(in: data, at: tiffOffset + 4, byteOrder: byteOrder),
              let ifdOffset = adding(tiffOffset, firstIFDOffset),
              let entryCount = readUInt16(in: data, at: ifdOffset, byteOrder: byteOrder) else {
            return nil
        }

        let entriesOffset = ifdOffset + 2
        for entryIndex in 0..<Int(entryCount) {
            let entryOffset = entriesOffset + entryIndex * 12
            guard let tag = readUInt16(in: data, at: entryOffset, byteOrder: byteOrder),
                  let fieldType = readUInt16(in: data, at: entryOffset + 2, byteOrder: byteOrder),
                  let valueCount = readUInt32(in: data, at: entryOffset + 4, byteOrder: byteOrder),
                  let valueOrOffset = readUInt32(in: data, at: entryOffset + 8, byteOrder: byteOrder) else {
                return nil
            }

            guard tag == canonAFInfo2Tag, fieldType == 3 else { continue }
            guard let byteCount = multiplying(valueCount, 2), byteCount >= 16 else { return nil }

            let valueOffset: Int
            if byteCount <= 4 {
                valueOffset = entryOffset + 8
            } else if let offset = adding(tiffOffset, valueOrOffset) {
                valueOffset = offset
            } else {
                return nil
            }

            guard hasRange(startingAt: valueOffset, length: byteCount, in: data) else { return nil }
            return target(
                inAFInfo2: data,
                offset: valueOffset,
                wordCount: byteCount / 2,
                byteOrder: byteOrder
            )
        }

        return nil
    }

    private static func target(
        inAFInfo2 data: Data,
        offset: Int,
        wordCount: Int,
        byteOrder: TIFFByteOrder
    ) -> CameraAFTarget? {
        func word(_ index: Int) -> UInt16? {
            guard index >= 0, index < wordCount else { return nil }
            return readUInt16(in: data, at: offset + index * 2, byteOrder: byteOrder)
        }

        // Canon AF Info 2 begins with: byte size, AF mode, number of points,
        // valid points, image dimensions, then four point-sized arrays for
        // widths, heights, X positions, and Y positions.
        guard let pointCountWord = word(2),
              let validPointCount = word(3),
              let imageWidthWord = word(6),
              let imageHeightWord = word(7) else {
            return nil
        }

        let pointCount = Int(pointCountWord)
        let imageWidth = Double(imageWidthWord)
        let imageHeight = Double(imageHeightWord)
        guard pointCount > 0,
              pointCount <= 20_000,
              validPointCount > 0,
              imageWidth > 0,
              imageHeight > 0 else {
            return nil
        }

        let bitsetWordCount = (pointCount + 15) / 16
        let requiredWordCount = 8 + 4 * pointCount + 2 * bitsetWordCount
        guard wordCount >= requiredWordCount else { return nil }

        let widthsOffset = 8
        let heightsOffset = widthsOffset + pointCount
        let xPositionsOffset = heightsOffset + pointCount
        let yPositionsOffset = xPositionsOffset + pointCount
        let focusBitsetOffset = yPositionsOffset + pointCount
        let selectedBitsetOffset = focusBitsetOffset + bitsetWordCount

        func hasBit(at pointIndex: Int, inBitsetStartingAt bitsetOffset: Int) -> Bool {
            guard let bits = word(bitsetOffset + pointIndex / 16) else { return false }
            return bits & (1 << UInt16(pointIndex % 16)) != 0
        }

        // Prefer the point Canon recorded as in focus. If the camera did not
        // record one, the selected point is still a useful visible target.
        let focusedCandidates = (0..<pointCount).compactMap { index in
            hasBit(at: index, inBitsetStartingAt: focusBitsetOffset)
                ? (index: index, state: CameraAFTarget.State.focused)
                : nil
        }
        let selectedCandidates = (0..<pointCount).compactMap { index in
            hasBit(at: index, inBitsetStartingAt: selectedBitsetOffset)
                ? (index: index, state: CameraAFTarget.State.selected)
                : nil
        }
        let candidates = focusedCandidates + selectedCandidates

        for candidate in candidates {
            guard let widthWord = word(widthsOffset + candidate.index),
                  let heightWord = word(heightsOffset + candidate.index),
                  let xWord = word(xPositionsOffset + candidate.index),
                  let yWord = word(yPositionsOffset + candidate.index) else {
                continue
            }

            let width = Double(Int16(bitPattern: widthWord))
            let height = Double(Int16(bitPattern: heightWord))
            guard width > 0, height > 0 else { continue }

            let x = Double(Int16(bitPattern: xWord))
            let y = Double(Int16(bitPattern: yWord))
            let center = CullInspectionPoint(
                x: 0.5 + x / imageWidth,
                y: 0.5 - y / imageHeight
            )
            return CameraAFTarget(
                center: center,
                width: min(width / imageWidth, 1),
                height: min(height / imageHeight, 1),
                state: candidate.state
            )
        }

        return nil
    }

    /// Finds a complete `CMT3` box with an immediately following TIFF header.
    /// Searching the bounded header is more resilient to CR3 box-layout
    /// variations than hard-coding an absolute offset, while the size and TIFF
    /// checks avoid treating arbitrary image bytes as metadata.
    private static func cmt3TIFFOffset(in data: Data) -> Int? {
        guard data.count >= 12 else { return nil }
        for boxStart in 0...(data.count - 12) {
            guard data[boxStart + 4] == 0x43, // C
                  data[boxStart + 5] == 0x4d, // M
                  data[boxStart + 6] == 0x54, // T
                  data[boxStart + 7] == 0x33, // 3
                  let boxLength = readBigEndianUInt32(in: data, at: boxStart),
                  boxLength >= 12,
                  let boxEnd = adding(boxStart, boxLength),
                  boxEnd <= data.count else {
                continue
            }

            let tiffOffset = boxStart + 8
            if TIFFByteOrder(at: tiffOffset, in: data) != nil {
                return tiffOffset
            }
        }
        return nil
    }

    private enum TIFFByteOrder {
        case littleEndian
        case bigEndian

        init?(at offset: Int, in data: Data) {
            guard hasRange(startingAt: offset, length: 2, in: data) else { return nil }
            switch (data[offset], data[offset + 1]) {
            case (0x49, 0x49): self = .littleEndian
            case (0x4d, 0x4d): self = .bigEndian
            default: return nil
            }
        }
    }

    private static func readUInt16(
        in data: Data,
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt16? {
        guard hasRange(startingAt: offset, length: 2, in: data) else { return nil }
        let first = UInt16(data[offset])
        let second = UInt16(data[offset + 1])
        switch byteOrder {
        case .littleEndian: return first | (second << 8)
        case .bigEndian: return (first << 8) | second
        }
    }

    private static func readUInt32(
        in data: Data,
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt32? {
        guard hasRange(startingAt: offset, length: 4, in: data) else { return nil }
        let bytes = (0..<4).map { UInt32(data[offset + $0]) }
        switch byteOrder {
        case .littleEndian:
            return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
        case .bigEndian:
            return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
        }
    }

    private static func readBigEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
        readUInt32(in: data, at: offset, byteOrder: .bigEndian)
    }

    private static func hasRange(startingAt offset: Int, length: Int, in data: Data) -> Bool {
        offset >= 0 && length >= 0 && offset <= data.count && length <= data.count - offset
    }

    private static func adding(_ offset: Int, _ value: UInt32) -> Int? {
        let value = Int(value)
        guard offset >= 0, value <= Int.max - offset else { return nil }
        return offset + value
    }

    private static func multiplying(_ value: UInt32, _ multiplier: Int) -> Int? {
        let value = Int(value)
        guard value <= Int.max / multiplier else { return nil }
        return value * multiplier
    }
}
