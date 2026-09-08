import AppKit
import Foundation
import ImageIO

/// Shared, bounded ImageIO cache. Keeping decoded images and I/O limits out of
/// SwiftUI presentation protects memory and external-drive responsiveness.
final class CullPreviewCache: @unchecked Sendable {
    static let shared = CullPreviewCache()

    private let previews = NSCache<NSString, NSImage>()
    private let fullPreviews = NSCache<NSURL, NSImage>()
    private let focusCrops = NSCache<NSString, NSImage>()
    private let fullPreviewGate = CullFullPreviewGate()
    private let focusCropGate = DispatchSemaphore(value: 2)

    private init() {
        previews.countLimit = 72
        previews.totalCostLimit = 140 * 1_024 * 1_024
        fullPreviews.countLimit = 1
        fullPreviews.totalCostLimit = 300 * 1_024 * 1_024
        focusCrops.countLimit = 24
        focusCrops.totalCostLimit = 80 * 1_024 * 1_024
    }

    func preview(for url: URL, maxPixelSize: Int) -> NSImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = previews.object(forKey: key) { return cached }
        guard let image = image(for: url, maxPixelSize: maxPixelSize) else { return nil }
        previews.setObject(image, forKey: key, cost: imageCost(image))
        return image
    }

    func fullPreview(for url: URL) async -> NSImage? {
        let key = url as NSURL
        if let cached = fullPreviews.object(forKey: key) { return cached }
        await fullPreviewGate.acquire()
        guard !Task.isCancelled else {
            await fullPreviewGate.release()
            return nil
        }
        if let cached = fullPreviews.object(forKey: key) {
            await fullPreviewGate.release()
            return cached
        }
        let decoded = await Task.detached(priority: .userInitiated) { [self] in
            image(for: url, maxPixelSize: 16_384)
        }.value
        if let decoded {
            fullPreviews.setObject(decoded, forKey: key, cost: imageCost(decoded))
        }
        await fullPreviewGate.release()
        return decoded
    }

    func focusCrop(for url: URL, around point: CullInspectionPoint) -> NSImage? {
        let key = "\(url.path)#focus#\(point.cacheKey)" as NSString
        if let cached = focusCrops.object(forKey: key) { return cached }
        focusCropGate.wait()
        defer { focusCropGate.signal() }
        if let cached = focusCrops.object(forKey: key) { return cached }
        guard let sourceImage = cgImage(for: url, maxPixelSize: 8_192) else { return nil }
        let cropRect = CullInspectionGeometry.cropRect(
            imageSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            around: point
        )
        guard let cropped = sourceImage.cropping(to: cropRect),
              let materialized = materialize(cropped, maximumPixelSize: 768) else {
            return nil
        }
        let image = NSImage(
            cgImage: materialized,
            size: NSSize(width: materialized.width, height: materialized.height)
        )
        focusCrops.setObject(image, forKey: key, cost: imageCost(image))
        return image
    }

    func prefetch(_ urls: [URL]) {
        for url in urls {
            _ = preview(for: url, maxPixelSize: CullPreviewSize.thumbnail.maxPixelSize)
        }
    }

    private func image(for url: URL, maxPixelSize: Int) -> NSImage? {
        guard let cgImage = cgImage(for: url, maxPixelSize: maxPixelSize) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func cgImage(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func materialize(_ image: CGImage, maximumPixelSize: Int) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > 0 else { return nil }
        let scale = min(1, CGFloat(maximumPixelSize) / CGFloat(longestEdge))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func imageCost(_ image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height * 4))
    }
}

private actor CullFullPreviewGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
