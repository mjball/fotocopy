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

/// The photographer's current magnification and image-relative center. It is
/// held by the burst review, rather than an individual frame preview, so
/// switching frames compares the same detail at the same scale.
struct CullPreviewViewport: Hashable {
    var zoom: CGFloat
    var center: CullInspectionPoint

    init(zoom: CGFloat = 1, center: CullInspectionPoint = CullInspectionPoint(x: 0.5, y: 0.5)) {
        self.zoom = min(max(zoom, 1), 6)
        self.center = center
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
    /// This is inferred from the file's location at scan time, rather than
    /// written to a catalog or sidecar. It lets a subsequent scan rebuild the
    /// visual Keep/Reject state from the date folder on disk.
    let disposition: CullDisposition?

    init(
        url: URL,
        filename: String,
        captureDate: Date?,
        dateSource: DateSource?,
        sequenceNumber: Int?,
        disposition: CullDisposition? = nil
    ) {
        self.url = url
        self.filename = filename
        self.captureDate = captureDate
        self.dateSource = dateSource
        self.sequenceNumber = sequenceNumber
        self.disposition = disposition
    }

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

/// The arrow-key policy for a single burst. Navigation stops at either end so
/// the selected frame position communicates when the burst is exhausted.
enum CullFrameNavigation {
    static func frameURL(
        in frames: [CullPhoto],
        adjacentTo selectedURL: URL?,
        offset: Int
    ) -> URL? {
        guard !frames.isEmpty else { return nil }
        guard offset != 0 else { return selectedURL ?? frames.first?.url }

        let currentIndex = frames.firstIndex { $0.url == selectedURL } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), frames.count - 1)
        return frames[nextIndex].url
    }
}

/// The cull workspace has three presentation densities. They never change the
/// files or the selected burst; they only decide how much surrounding UI the
/// photo preview shares space with.
enum CullReviewLayout: String, CaseIterable, Identifiable {
    case browse
    case review
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .review: return "Review"
        case .focus: return "Focus"
        }
    }
}

/// Cull has a focused per-day burst review and a library-wide, filesystem
/// backed decision review. Neither owns a separate photo catalog.
enum CullDestination: Hashable {
    case bursts
    case libraryDecisions
}

/// Burst navigation mirrors frame navigation: the endpoints deliberately do
/// not wrap, so an up/down press never jumps to a distant shoot.
enum CullBurstNavigation {
    static func burstID(
        in bursts: [PhotoBurst],
        adjacentTo selectedBurstID: URL?,
        offset: Int
    ) -> URL? {
        guard !bursts.isEmpty else { return nil }
        guard offset != 0 else { return selectedBurstID ?? bursts.first?.id }

        let currentIndex = bursts.firstIndex { $0.id == selectedBurstID } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), bursts.count - 1)
        return bursts[nextIndex].id
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
        let scanFiles = try reviewFiles(in: folder)

        let workers = min(max(1, workerCount), max(1, scanFiles.count))
        let photos = await readPhotos(scanFiles, workerCount: workers, progress: progress)
        let ordered = photos.sorted(by: isOrderedBefore)
        let grouped = group(ordered, configuration: configuration)

        return CullFolderScan(
            folder: folder,
            cr3Count: scanFiles.count,
            unreadableMetadataCount: photos.filter { $0.captureDate == nil }.count,
            bursts: grouped.bursts,
            singleFrames: grouped.singles,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// A cull scan treats the chosen date folder as the source of truth. It
    /// also reads Fotocopy's two immediate decision folders so that moving a
    /// frame to Keeps or Rejects does not split the burst after relaunch.
    /// Other subfolders deliberately remain outside the cull scan.
    private static func reviewFiles(in folder: URL) throws -> [IndexedURL] {
        let rootFiles = try cr3Files(in: folder).map {
            IndexedURL(url: $0, disposition: nil)
        }
        let decisionFiles = try CullDisposition.allCases.flatMap { disposition in
            let decisionFolder = folder.appendingPathComponent(
                disposition.destinationFolderName,
                isDirectory: true
            )
            return try cr3Files(in: decisionFolder).map {
                IndexedURL(url: $0, disposition: disposition)
            }
        }

        return (rootFiles + decisionFiles).sorted {
            let filenameOrder = $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
            if filenameOrder != .orderedSame {
                return filenameOrder == .orderedAscending
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private static func cr3Files(in directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame
        }
    }

    private static func readPhotos(
        _ files: [IndexedURL],
        workerCount: Int,
        progress: @escaping @Sendable (CullScanProgress) -> Void
    ) async -> [CullPhoto] {
        guard !files.isEmpty else { return [] }

        return await withTaskGroup(of: IndexedPhoto.self) { group in
            var nextIndex = 0
            let initialCount = min(workerCount, files.count)
            for index in 0..<initialCount {
                group.addTask { await photo(at: files[index], index: index) }
                nextIndex = index + 1
            }

            var results = [IndexedPhoto?](repeating: nil, count: files.count)
            var completed = 0
            let progressStride = max(1, files.count / 100)

            while let output = await group.next() {
                results[output.index] = output
                completed += 1
                if completed == files.count || completed.isMultiple(of: progressStride) {
                    progress(CullScanProgress(
                        completed: completed,
                        total: files.count,
                        filename: output.photo.filename
                    ))
                }
                if nextIndex < files.count {
                    let index = nextIndex
                    group.addTask { await photo(at: files[index], index: index) }
                    nextIndex += 1
                }
            }

            return results.compactMap { $0?.photo }
        }
    }

    private static func photo(at file: IndexedURL, index: Int) async -> IndexedPhoto {
        let metadata = await EXIFDateReader.readMetadata(from: file.url)
        return IndexedPhoto(
            index: index,
            photo: CullPhoto(
                url: file.url,
                filename: file.url.lastPathComponent,
                captureDate: metadata.dateResult?.date,
                dateSource: metadata.dateResult?.source,
                sequenceNumber: sequenceNumber(in: file.url),
                disposition: file.disposition
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

private struct IndexedURL: Sendable {
    let url: URL
    let disposition: CullDisposition?
}
