import Foundation
import ImageIO
import AVFoundation

enum DateSource {
    case exif
    case quickTime
    case filesystem
}

struct DateResult {
    let date: Date
    let source: DateSource
}

enum EXIFDateReader {
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func readDate(from url: URL) async -> DateResult? {
        if let result = readImageDate(from: url) {
            return result
        }
        if let result = await readVideoDate(from: url) {
            return result
        }
        return readFilesystemDate(from: url)
    }

    private static func readImageDate(from url: URL) -> DateResult? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let date = exifDateFormatter.date(from: dateStr) {
                return DateResult(date: date, source: .exif)
            }
            if let dateStr = exif[kCGImagePropertyExifDateTimeDigitized] as? String,
               let date = exifDateFormatter.date(from: dateStr) {
                return DateResult(date: date, source: .exif)
            }
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateStr = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifDateFormatter.date(from: dateStr) {
            return DateResult(date: date, source: .exif)
        }

        return nil
    }

    private static func readVideoDate(from url: URL) async -> DateResult? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let metadataItem = try? await asset.load(.creationDate),
              let dateValue = try? await metadataItem.load(.dateValue) else {
            return nil
        }
        return DateResult(date: dateValue, source: .quickTime)
    }

    private static func readFilesystemDate(from url: URL) -> DateResult? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.creationDate] as? Date else { return nil }
        return DateResult(date: date, source: .filesystem)
    }
}
