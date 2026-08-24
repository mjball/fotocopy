import CoreGraphics
import Foundation

/// A point chosen by the photographer in the displayed image, expressed as a
/// fraction of the image width and height. Keeping it normalized means the
/// cull view can inspect the corresponding part of every frame in a burst
/// without creating any file-side state.
struct CullInspectionPoint: Sendable, Hashable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    /// A stable, deliberately coarse cache component. A one-thousandth of the
    /// image is more precise than a click in the review UI, while avoiding a
    /// new cached crop for insignificant pointer variation.
    var cacheKey: String {
        "\(Int((x * 1_000).rounded()))-\(Int((y * 1_000).rounded()))"
    }
}

/// Which target drives the detailed, frame-by-frame crop review. A manual
/// choice always takes precedence over the optional camera-recorded AF data.
enum CullInspectionSource: Sendable, Hashable {
    case manual(CullInspectionPoint)
    case cameraAF

    var manualPoint: CullInspectionPoint? {
        guard case let .manual(point) = self else { return nil }
        return point
    }
}

enum CullInspectionGeometry {
    static func fittedImageRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func normalizedPoint(
        for location: CGPoint,
        imageSize: CGSize,
        in containerSize: CGSize
    ) -> CullInspectionPoint? {
        let imageRect = fittedImageRect(imageSize: imageSize, in: containerSize)
        guard imageRect.contains(location), imageRect.width > 0, imageRect.height > 0 else { return nil }
        return CullInspectionPoint(
            x: Double((location.x - imageRect.minX) / imageRect.width),
            y: Double((location.y - imageRect.minY) / imageRect.height)
        )
    }

    /// Returns a square crop in image pixel coordinates. The crop follows the
    /// same top-left origin convention as the SwiftUI image view.
    static func cropRect(
        imageSize: CGSize,
        around point: CullInspectionPoint,
        fractionOfShortEdge: CGFloat = 0.16
    ) -> CGRect {
        let shortEdge = min(imageSize.width, imageSize.height)
        let side = min(shortEdge, max(1, shortEdge * fractionOfShortEdge))
        let maximumX = max(0, imageSize.width - side)
        let maximumY = max(0, imageSize.height - side)
        let centeredX = CGFloat(point.x) * imageSize.width - side / 2
        let centeredY = CGFloat(point.y) * imageSize.height - side / 2
        return CGRect(
            x: min(max(centeredX, 0), maximumX),
            y: min(max(centeredY, 0), maximumY),
            width: side,
            height: side
        ).integral
    }
}

/// The culling workspace deliberately works with files in place. These models
/// describe one selected folder; they are not a photo catalog or library.
struct CullPhoto: Identifiable, Sendable, Hashable {
    let url: URL
    let filename: String
    let captureDate: Date?
    let dateSource: DateSource?
    let sequenceNumber: Int?

    var id: URL { url }
}

struct PhotoBurst: Identifiable, Sendable, Hashable {
    let frames: [CullPhoto]

    var id: URL { frames[0].url }
    var firstFrame: CullPhoto { frames[0] }
    var title: String {
        guard let lastFrame = frames.last, lastFrame.url != firstFrame.url else {
            return firstFrame.filename
        }
        return "\(firstFrame.filename) – \(lastFrame.filename)"
    }

    var captureRange: (start: Date?, end: Date?) {
        (frames.first?.captureDate, frames.last?.captureDate)
    }
}

/// The arrow-key policy for a single burst. It wraps at either end so a
/// photographer can keep comparing frames without moving keyboard focus into
/// the burst list.
enum CullFrameNavigation {
    static func frameURL(
        in frames: [CullPhoto],
        adjacentTo selectedURL: URL?,
        offset: Int
    ) -> URL? {
        guard !frames.isEmpty else { return nil }
        guard offset != 0 else { return selectedURL ?? frames.first?.url }

        let currentIndex = frames.firstIndex { $0.url == selectedURL } ?? 0
        let nextIndex = (currentIndex + offset % frames.count + frames.count) % frames.count
        return frames[nextIndex].url
    }
}

struct CullFolderScan: Sendable {
    let folder: URL
    let cr3Count: Int
    let unreadableMetadataCount: Int
    let bursts: [PhotoBurst]
    let singleFrames: [CullPhoto]
    let duration: TimeInterval
}

struct CullScanProgress: Sendable {
    let completed: Int
    let total: Int
    let filename: String
}

struct BurstGroupingConfiguration: Sendable {
    /// A break of this size almost always represents a new action rather than
    /// a continuous burst. It is deliberately conservative: false splits are
    /// easier to correct than falsely merged scenes.
    var maximumCaptureGap: TimeInterval = 1.25

    /// When filenames cannot be parsed, only very tightly spaced captures are
    /// grouped by time alone.
    var maximumGapWithoutSequenceNumbers: TimeInterval = 0.35
}

enum BurstGroupingEngine {
    static func scan(
        folder: URL,
        workerCount: Int,
        configuration: BurstGroupingConfiguration = BurstGroupingConfiguration(),
        progress: @escaping @Sendable (CullScanProgress) -> Void
    ) async throws -> CullFolderScan {
        let started = Date()
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let workers = min(max(1, workerCount), max(1, urls.count))
        let photos = await readPhotos(urls, workerCount: workers, progress: progress)
        let ordered = photos.sorted(by: isOrderedBefore)
        let grouped = group(ordered, configuration: configuration)

        return CullFolderScan(
            folder: folder,
            cr3Count: urls.count,
            unreadableMetadataCount: photos.filter { $0.captureDate == nil }.count,
            bursts: grouped.bursts,
            singleFrames: grouped.singles,
            duration: Date().timeIntervalSince(started)
        )
    }

    private static func readPhotos(
        _ urls: [URL],
        workerCount: Int,
        progress: @escaping @Sendable (CullScanProgress) -> Void
    ) async -> [CullPhoto] {
        guard !urls.isEmpty else { return [] }

        return await withTaskGroup(of: IndexedPhoto.self) { group in
            var nextIndex = 0
            let initialCount = min(workerCount, urls.count)
            for index in 0..<initialCount {
                group.addTask { await photo(at: urls[index], index: index) }
                nextIndex = index + 1
            }

            var results = [IndexedPhoto?](repeating: nil, count: urls.count)
            var completed = 0
            let progressStride = max(1, urls.count / 100)

            while let output = await group.next() {
                results[output.index] = output
                completed += 1
                if completed == urls.count || completed.isMultiple(of: progressStride) {
                    progress(CullScanProgress(
                        completed: completed,
                        total: urls.count,
                        filename: output.photo.filename
                    ))
                }
                if nextIndex < urls.count {
                    let index = nextIndex
                    group.addTask { await photo(at: urls[index], index: index) }
                    nextIndex += 1
                }
            }

            return results.compactMap { $0?.photo }
        }
    }

    private static func photo(at url: URL, index: Int) async -> IndexedPhoto {
        let metadata = await EXIFDateReader.readMetadata(from: url)
        return IndexedPhoto(
            index: index,
            photo: CullPhoto(
                url: url,
                filename: url.lastPathComponent,
                captureDate: metadata.dateResult?.date,
                dateSource: metadata.dateResult?.source,
                sequenceNumber: sequenceNumber(in: url)
            )
        )
    }

    private static func isOrderedBefore(_ lhs: CullPhoto, _ rhs: CullPhoto) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }

    static func group(
        _ photos: [CullPhoto],
        configuration: BurstGroupingConfiguration
    ) -> (bursts: [PhotoBurst], singles: [CullPhoto]) {
        var bursts: [PhotoBurst] = []
        var singles: [CullPhoto] = []
        var active: [CullPhoto] = []

        func finishActive() {
            guard !active.isEmpty else { return }
            if active.count > 1 {
                bursts.append(PhotoBurst(frames: active))
            } else if let photo = active.first {
                singles.append(photo)
            }
        }

        for photo in photos {
            if let previous = active.last, shouldJoin(
                previous,
                photo,
                configuration: configuration
            ) {
                active.append(photo)
            } else {
                finishActive()
                active = [photo]
            }
        }
        finishActive()
        return (bursts, singles)
    }

    private static func shouldJoin(
        _ previous: CullPhoto,
        _ next: CullPhoto,
        configuration: BurstGroupingConfiguration
    ) -> Bool {
        let sequential: Bool? = {
            guard let previousNumber = previous.sequenceNumber,
                  let nextNumber = next.sequenceNumber else { return nil }
            return nextNumber == previousNumber + 1
        }()

        switch (previous.captureDate, next.captureDate) {
        case let (previousDate?, nextDate?):
            let gap = nextDate.timeIntervalSince(previousDate)
            guard gap >= 0, gap <= configuration.maximumCaptureGap else { return false }
            return sequential ?? (gap <= configuration.maximumGapWithoutSequenceNumbers)
        case (nil, nil):
            return sequential == true
        default:
            return false
        }
    }

    static func sequenceNumber(in url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        let terminalDigits = stem.reversed().prefix(while: { $0.isNumber })
        guard !terminalDigits.isEmpty else { return nil }

        let terminal = String(terminalDigits.reversed())
        let prefix = String(stem.dropLast(terminal.count))

        // Fotocopy adds `_1` to resolve a name collision. In that case recover
        // the camera sequence number before the suffix where possible.
        if prefix.last == "_" {
            let originalStem = String(prefix.dropLast())
            let originalDigits = originalStem.reversed().prefix(while: { $0.isNumber })
            if !originalDigits.isEmpty, let originalNumber = Int(String(originalDigits.reversed())) {
                return originalNumber
            }
        }

        return Int(terminal)
    }
}

private struct IndexedPhoto: Sendable {
    let index: Int
    let photo: CullPhoto
}
