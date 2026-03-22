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

    private static let exifDateWithTZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let exifDateWithSubSecTZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss.SSxxx"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let iptcDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd HHmmssxx"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let iptcDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
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

    static func readCameraModel(from url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String {
            return model.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func readImageDate(from url: URL) -> DateResult? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let offsetOriginal = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let offsetDigitized = exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String
        let offsetGeneral = exif?[kCGImagePropertyExifOffsetTime] as? String
        let subSecOriginal = exif?["SubSecTimeOriginal" as CFString] as? String
        let subSecDigitized = exif?["SubSecTimeDigitized" as CFString] as? String

        if let dateStr = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            if let date = parseExifDate(dateStr, offset: offsetOriginal ?? offsetGeneral, subSec: subSecOriginal) {
                return DateResult(date: date, source: .exif)
            }
        }

        if let dateStr = exif?[kCGImagePropertyExifDateTimeDigitized] as? String {
            if let date = parseExifDate(dateStr, offset: offsetDigitized ?? offsetGeneral, subSec: subSecDigitized) {
                return DateResult(date: date, source: .exif)
            }
        }

        if let dateStr = tiff?[kCGImagePropertyTIFFDateTime] as? String {
            if let date = parseExifDate(dateStr, offset: offsetGeneral, subSec: nil) {
                return DateResult(date: date, source: .exif)
            }
        }

        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if let date = parseIPTCDate(iptc) {
                return DateResult(date: date, source: .exif)
            }
        }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let date = parseGPSDate(gps) {
                return DateResult(date: date, source: .exif)
            }
        }

        return nil
    }

    static func parseExifDate(_ dateStr: String, offset: String?, subSec: String?) -> Date? {
        if let offset {
            if let subSec, !subSec.isEmpty {
                let combined = "\(dateStr).\(subSec)\(offset)"
                if let date = exifDateWithSubSecTZFormatter.date(from: combined) {
                    return date
                }
            }
            let combined = "\(dateStr)\(offset)"
            if let date = exifDateWithTZFormatter.date(from: combined) {
                return date
            }
        }

        if let subSec, !subSec.isEmpty {
            let withSubSec = "\(dateStr).\(subSec)+00:00"
            if let date = exifDateWithSubSecTZFormatter.date(from: withSubSec) {
                return date
            }
        }

        return exifDateFormatter.date(from: dateStr)
    }

    static func parseIPTCDate(_ iptc: [CFString: Any]) -> Date? {
        guard let dateStr = iptc[kCGImagePropertyIPTCDateCreated] as? String else { return nil }
        if let timeStr = iptc[kCGImagePropertyIPTCTimeCreated] as? String {
            let combined = "\(dateStr) \(timeStr)"
            if let date = iptcDateFormatter.date(from: combined) {
                return date
            }
        }
        return iptcDateOnlyFormatter.date(from: dateStr)
    }

    static func parseGPSDate(_ gps: [CFString: Any]) -> Date? {
        guard let dateStr = gps[kCGImagePropertyGPSDateStamp] as? String,
              let timeStr = gps[kCGImagePropertyGPSTimeStamp] as? String else { return nil }
        let combined = "\(dateStr) \(timeStr)"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: combined)
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
