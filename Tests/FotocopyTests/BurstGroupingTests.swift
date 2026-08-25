import Foundation
import Testing
@testable import Fotocopy

@Test func consecutiveCapturesBecomeOneBurst() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let photos = [
        makePhoto(number: 2496, at: start),
        makePhoto(number: 2497, at: start.addingTimeInterval(0.06)),
        makePhoto(number: 2498, at: start.addingTimeInterval(0.12))
    ]

    let result = BurstGroupingEngine.group(photos, configuration: BurstGroupingConfiguration())

    #expect(result.bursts.count == 1)
    #expect(result.bursts[0].frames.count == 3)
    #expect(result.singles.isEmpty)
}

@Test func largeCaptureGapSplitsOtherwiseConsecutiveFrames() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let photos = [
        makePhoto(number: 2496, at: start),
        makePhoto(number: 2497, at: start.addingTimeInterval(0.05)),
        makePhoto(number: 2498, at: start.addingTimeInterval(2.0)),
        makePhoto(number: 2499, at: start.addingTimeInterval(2.05))
    ]

    let result = BurstGroupingEngine.group(photos, configuration: BurstGroupingConfiguration())

    #expect(result.bursts.map { $0.frames.count } == [2, 2])
}

@Test func missingSequenceNumbersNeedACloserCaptureGap() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let photos = [
        CullPhoto(
            url: URL(fileURLWithPath: "/tmp/first.CR3"),
            filename: "first.CR3",
            captureDate: start,
            dateSource: .exif,
            sequenceNumber: nil
        ),
        CullPhoto(
            url: URL(fileURLWithPath: "/tmp/second.CR3"),
            filename: "second.CR3",
            captureDate: start.addingTimeInterval(0.5),
            dateSource: .exif,
            sequenceNumber: nil
        )
    ]

    let result = BurstGroupingEngine.group(photos, configuration: BurstGroupingConfiguration())

    #expect(result.bursts.isEmpty)
    #expect(result.singles.count == 2)
}

@Test func collisionSuffixUsesOriginalCameraSequenceNumber() {
    #expect(BurstGroupingEngine.sequenceNumber(in: URL(fileURLWithPath: "/tmp/BL5A2496_1.CR3")) == 2496)
    #expect(BurstGroupingEngine.sequenceNumber(in: URL(fileURLWithPath: "/tmp/IMG_7422.CR3")) == 7422)
}

@Test func scanRebuildsBurstAndCullStateFromDecisionFolders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fotocopy-burst-scan-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let selects = root.appendingPathComponent("Selects", isDirectory: true)
    let rejects = root.appendingPathComponent("Rejects", isDirectory: true)
    try FileManager.default.createDirectory(at: selects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rejects, withIntermediateDirectories: true)
    try Data([0]).write(to: root.appendingPathComponent("BL5A1001.CR3"))
    try Data([0]).write(to: selects.appendingPathComponent("BL5A1002.CR3"))
    try Data([0]).write(to: rejects.appendingPathComponent("BL5A1003.CR3"))
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Elsewhere", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data([0]).write(to: root.appendingPathComponent("Elsewhere/BL5A1004.CR3"))

    let scan = try await BurstGroupingEngine.scan(
        folder: root,
        workerCount: 2,
        progress: { _ in }
    )

    #expect(scan.cr3Count == 3)
    #expect(scan.bursts.count == 1)
    #expect(scan.bursts[0].frames.map(\.filename) == [
        "BL5A1001.CR3",
        "BL5A1002.CR3",
        "BL5A1003.CR3"
    ])
    #expect(scan.bursts[0].frames.map(\.disposition) == [nil, .select, .reject])
}

@Test func inspectionPointUsesOnlyTheVisibleAspectFitImage() {
    let imageSize = CGSize(width: 4_000, height: 2_000)
    let containerSize = CGSize(width: 400, height: 400)

    let point = CullInspectionGeometry.normalizedPoint(
        for: CGPoint(x: 200, y: 200),
        imageSize: imageSize,
        in: containerSize
    )

    #expect(point == CullInspectionPoint(x: 0.5, y: 0.5))
    #expect(CullInspectionGeometry.normalizedPoint(
        for: CGPoint(x: 200, y: 50),
        imageSize: imageSize,
        in: containerSize
    ) == nil)
}

@Test func inspectionCropStaysCenteredAndClampedToImageEdges() {
    let imageSize = CGSize(width: 4_000, height: 2_000)
    let center = CullInspectionGeometry.cropRect(
        imageSize: imageSize,
        around: CullInspectionPoint(x: 0.5, y: 0.5)
    )
    let lowerRight = CullInspectionGeometry.cropRect(
        imageSize: imageSize,
        around: CullInspectionPoint(x: 1, y: 1)
    )

    #expect(center == CGRect(x: 1_840, y: 840, width: 320, height: 320))
    #expect(lowerRight == CGRect(x: 3_680, y: 1_680, width: 320, height: 320))
}

@Test func arrowNavigationMovesThroughBurstAndStopsAtEachEnd() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let frames = [
        makePhoto(number: 1, at: start),
        makePhoto(number: 2, at: start.addingTimeInterval(0.1)),
        makePhoto(number: 3, at: start.addingTimeInterval(0.2))
    ]

    #expect(CullFrameNavigation.frameURL(
        in: frames,
        adjacentTo: frames[1].url,
        offset: 1
    ) == frames[2].url)
    #expect(CullFrameNavigation.frameURL(
        in: frames,
        adjacentTo: frames[2].url,
        offset: 1
    ) == frames[2].url)
    #expect(CullFrameNavigation.frameURL(
        in: frames,
        adjacentTo: frames[0].url,
        offset: -1
    ) == frames[0].url)
}

@Test func canonAFInfo2UsesFocusedRectangleAndConvertsItsCoordinates() {
    let target = CanonAFMetadataReader.target(from: canonAFInfo2Fixture(
        focusedBitset: 0b10,
        selectedBitset: 0b1
    ))

    #expect(target?.state == .focused)
    #expect(target?.center == CullInspectionPoint(x: 0.55, y: 0.55))
    #expect(target?.width == 0.04)
    #expect(target?.height == 0.02)
    #expect(abs((target?.normalizedRect.minX ?? 0) - 0.53) < 0.000_001)
    #expect(abs((target?.normalizedRect.minY ?? 0) - 0.54) < 0.000_001)
    #expect(abs((target?.normalizedRect.width ?? 0) - 0.04) < 0.000_001)
    #expect(abs((target?.normalizedRect.height ?? 0) - 0.02) < 0.000_001)
}

@Test func canonAFInfo2FallsBackToTheSelectedRectangle() {
    let target = CanonAFMetadataReader.target(from: canonAFInfo2Fixture(
        focusedBitset: 0,
        selectedBitset: 0b1
    ))

    #expect(target?.state == .selected)
    #expect(target?.center == CullInspectionPoint(x: 0.4, y: 0.4))
}

@Test func canonAFReaderRejectsIncompleteMetadata() {
    #expect(CanonAFMetadataReader.target(from: Data([0, 0, 0, 12, 0x43, 0x4d, 0x54, 0x33])) == nil)
}

private func makePhoto(number: Int, at date: Date) -> CullPhoto {
    let filename = "BL5A\(number).CR3"
    return CullPhoto(
        url: URL(fileURLWithPath: "/tmp/\(filename)"),
        filename: filename,
        captureDate: date,
        dateSource: .exif,
        sequenceNumber: number
    )
}

private func canonAFInfo2Fixture(focusedBitset: UInt16, selectedBitset: UInt16) -> Data {
    let pointCount = 3
    let words: [UInt16] = [
        44, 22, UInt16(pointCount), UInt16(pointCount), 10_000, 10_000, 10_000, 10_000,
        100, 400, 200, // widths
        100, 200, 100, // heights
        UInt16(bitPattern: -1_000), 500, 1_300, // X from image centre
        1_000, UInt16(bitPattern: -500), UInt16(bitPattern: -800), // positive Y is up
        focusedBitset,
        selectedBitset
    ]

    var tiff = Data([0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00])
    appendLittleEndian(UInt16(1), to: &tiff) // IFD entry count
    appendLittleEndian(UInt16(0x0026), to: &tiff)
    appendLittleEndian(UInt16(3), to: &tiff) // TIFF short
    appendLittleEndian(UInt32(words.count), to: &tiff)
    appendLittleEndian(UInt32(64), to: &tiff)
    appendLittleEndian(UInt32(0), to: &tiff) // next IFD
    tiff.append(Data(repeating: 0, count: 64 - tiff.count))
    for word in words {
        appendLittleEndian(word, to: &tiff)
    }

    var data = Data(repeating: 0, count: 16)
    appendBigEndian(UInt32(tiff.count + 8), to: &data)
    data.append(Data("CMT3".utf8))
    data.append(tiff)
    return data
}

private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value >> 24))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value))
}
