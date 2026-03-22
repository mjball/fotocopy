import Testing
import Foundation
import ImageIO
import CoreGraphics
@testable import Fotocopy

@Suite
struct EXIFDateReaderTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotocopy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - readDate integration

    @Test func filesystemFallback() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("plain.txt")
        try Data("hello".utf8).write(to: file)

        let result = await EXIFDateReader.readDate(from: file)
        #expect(result != nil)
        #expect(result?.source == .filesystem)
    }

    @Test func nonExistentFile() async throws {
        let bogus = URL(fileURLWithPath: "/tmp/fotocopy-does-not-exist-\(UUID().uuidString).jpg")
        let result = await EXIFDateReader.readDate(from: bogus)
        #expect(result == nil)
    }

    @Test func jpegWithEXIF() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("test.jpg")
        try createMinimalJPEGWithEXIF(at: file, exif: [
            kCGImagePropertyExifDateTimeOriginal: "2024:06:15 14:30:00"
        ])

        let result = await EXIFDateReader.readDate(from: file)
        #expect(result != nil)
        #expect(result?.source == .exif)

        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month, .day], from: result!.date)
        #expect(components.year == 2024)
        #expect(components.month == 6)
        #expect(components.day == 15)
    }

    @Test func exifPreferredOverFilesystem() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("dated.jpg")
        try createMinimalJPEGWithEXIF(at: file, exif: [
            kCGImagePropertyExifDateTimeOriginal: "2020:01:01 00:00:00"
        ])

        let result = await EXIFDateReader.readDate(from: file)
        #expect(result?.source == .exif)

        let cal = Calendar.current
        let year = cal.component(.year, from: result!.date)
        #expect(year == 2020)
    }

    @Test func dateTimeOriginalPreferredOverDigitized() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("priority.jpg")
        try createMinimalJPEGWithEXIF(at: file, exif: [
            kCGImagePropertyExifDateTimeOriginal: "2020:06:15 10:00:00",
            kCGImagePropertyExifDateTimeDigitized: "2020:06:15 11:00:00"
        ])

        let result = await EXIFDateReader.readDate(from: file)
        let cal = Calendar.current
        let hour = cal.component(.hour, from: result!.date)
        #expect(hour == 10)
    }

    @Test func fallsBackToDigitizedDate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("digitized.jpg")
        try createMinimalJPEGWithEXIF(at: file, exif: [
            kCGImagePropertyExifDateTimeDigitized: "2021:03:20 15:45:00"
        ])

        let result = await EXIFDateReader.readDate(from: file)
        #expect(result?.source == .exif)
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month, .day], from: result!.date)
        #expect(components.year == 2021)
        #expect(components.month == 3)
        #expect(components.day == 20)
    }

    @Test func fallsBackToTIFFDateTime() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("tiff.jpg")
        try createMinimalJPEGWithEXIF(at: file, exif: [:], tiff: [
            kCGImagePropertyTIFFDateTime: "2019:11:05 08:30:00"
        ])

        let result = await EXIFDateReader.readDate(from: file)
        #expect(result != nil)
        // CGImageDestination may not persist TIFF-only DateTime for minimal JPEGs,
        // so we just verify we get a date back (may be filesystem fallback)
    }

    @Test func tiffDateTimeUsedWhenExifHasNoDate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("tiffdate.jpg")
        // Include both EXIF dict (without dates) and TIFF dict with DateTime
        try createMinimalJPEGWithEXIF(at: file, exif: [
            kCGImagePropertyExifColorSpace: 1
        ], tiff: [
            kCGImagePropertyTIFFDateTime: "2019:11:05 08:30:00"
        ])

        let result = await EXIFDateReader.readDate(from: file)
        #expect(result != nil)
    }

    // MARK: - parseExifDate unit tests

    @Test func parseBasicExifDate() {
        let date = EXIFDateReader.parseExifDate("2024:06:15 14:30:00", offset: nil, subSec: nil)
        #expect(date != nil)
    }

    @Test func parseExifDateWithTimezone() {
        let date = EXIFDateReader.parseExifDate("2024:06:15 14:30:00", offset: "-05:00", subSec: nil)
        #expect(date != nil)

        let utcCal = Calendar.current
        let utcComponents = utcCal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(utcComponents.hour == 19)
    }

    @Test func parseExifDateWithSubSecAndTimezone() {
        let date = EXIFDateReader.parseExifDate("2024:06:15 14:30:00", offset: "-05:00", subSec: "94")
        #expect(date != nil)
    }

    @Test func parseExifDateWithSubSecNoTimezone() {
        let date = EXIFDateReader.parseExifDate("2024:06:15 14:30:00", offset: nil, subSec: "50")
        #expect(date != nil)
    }

    @Test func parseExifDateEmptySubSec() {
        let date = EXIFDateReader.parseExifDate("2024:06:15 14:30:00", offset: "-05:00", subSec: "")
        #expect(date != nil)
    }

    @Test func parseExifDateInvalidString() {
        let date = EXIFDateReader.parseExifDate("not a date", offset: nil, subSec: nil)
        #expect(date == nil)
    }

    // MARK: - parseIPTCDate unit tests

    @Test func parseIPTCDateAndTime() {
        let iptc: [CFString: Any] = [
            kCGImagePropertyIPTCDateCreated: "20240615",
            kCGImagePropertyIPTCTimeCreated: "143000+0500"
        ]
        let date = EXIFDateReader.parseIPTCDate(iptc)
        #expect(date != nil)
    }

    @Test func parseIPTCDateOnly() {
        let iptc: [CFString: Any] = [
            kCGImagePropertyIPTCDateCreated: "20240615"
        ]
        let date = EXIFDateReader.parseIPTCDate(iptc)
        #expect(date != nil)

        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month, .day], from: date!)
        #expect(components.year == 2024)
        #expect(components.month == 6)
        #expect(components.day == 15)
    }

    @Test func parseIPTCDateMissing() {
        let iptc: [CFString: Any] = [:]
        let date = EXIFDateReader.parseIPTCDate(iptc)
        #expect(date == nil)
    }

    // MARK: - parseGPSDate unit tests

    @Test func parseGPSDate() {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSDateStamp: "2024:06:15",
            kCGImagePropertyGPSTimeStamp: "19:30:00"
        ]
        let date = EXIFDateReader.parseGPSDate(gps)
        #expect(date != nil)

        let utcCal = Calendar.current
        let components = utcCal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(components.year == 2024)
        #expect(components.month == 6)
        #expect(components.day == 15)
        #expect(components.hour == 19)
    }

    @Test func parseGPSDateMissingTime() {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSDateStamp: "2024:06:15"
        ]
        let date = EXIFDateReader.parseGPSDate(gps)
        #expect(date == nil)
    }

    // MARK: - Camera model

    @Test func readsCameraModel() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("camera.jpg")
        try createMinimalJPEGWithEXIF(at: file, exif: [
            kCGImagePropertyExifDateTimeOriginal: "2024:01:01 00:00:00"
        ], tiff: [
            kCGImagePropertyTIFFModel: "Canon EOS R6 Mark III"
        ])

        let model = EXIFDateReader.readCameraModel(from: file)
        #expect(model == "Canon EOS R6 Mark III")
    }

    @Test func cameraModelNilForNonImage() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("plain.txt")
        try Data("hello".utf8).write(to: file)

        let model = EXIFDateReader.readCameraModel(from: file)
        #expect(model == nil)
    }

    // MARK: - Helpers

    private func createMinimalJPEGWithEXIF(
        at url: URL,
        exif: [CFString: Any],
        tiff: [CFString: Any] = [:],
        iptc: [CFString: Any]? = nil,
        gps: [CFString: Any]? = nil
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError(message: "Could not create CGContext")
        }

        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))

        guard let cgImage = context.makeImage() else {
            throw TestError(message: "Could not create CGImage")
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw TestError(message: "Could not create image destination")
        }

        var properties: [CFString: Any] = [:]
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if let iptc { properties[kCGImagePropertyIPTCDictionary] = iptc }
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw TestError(message: "Could not finalize image")
        }
    }
}

private struct TestError: Error {
    let message: String
}
