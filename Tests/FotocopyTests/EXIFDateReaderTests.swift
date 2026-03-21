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
        try createMinimalJPEGWithEXIF(at: file, dateString: "2024:06:15 14:30:00")

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
        try createMinimalJPEGWithEXIF(at: file, dateString: "2020:01:01 00:00:00")

        let result = await EXIFDateReader.readDate(from: file)
        #expect(result?.source == .exif)

        let cal = Calendar.current
        let year = cal.component(.year, from: result!.date)
        #expect(year == 2020)
    }

    @Test func readsCameraModel() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("camera.jpg")
        try createMinimalJPEGWithEXIF(at: file, dateString: "2024:01:01 00:00:00", cameraModel: "Canon EOS R6 Mark III")

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

    private func createMinimalJPEGWithEXIF(at url: URL, dateString: String, cameraModel: String? = nil) throws {
        let width = 1
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError(message: "Could not create CGContext")
        }

        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw TestError(message: "Could not create CGImage")
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw TestError(message: "Could not create image destination")
        }

        let exifProperties: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: dateString
        ]
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exifProperties
        ]
        if let cameraModel {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFModel: cameraModel
            ] as [CFString: Any]
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw TestError(message: "Could not finalize image")
        }
    }
}

private struct TestError: Error {
    let message: String
}
