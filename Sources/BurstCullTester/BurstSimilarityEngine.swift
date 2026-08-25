import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Controls only how already-measured adjacent pairs are grouped. Moving this
/// value never re-reads a CR3; it simply applies new limits to cached metrics.
struct BurstSimilarityConfiguration: Sendable {
    /// 0 is permissive and 1 is strict.
    let strictness: Double

    var minimumSceneCorrelation: Double { 0.89 + (strictness * 0.075) }
    var maximumHashDistance: Int { Int((18 - (strictness * 10)).rounded()) }
    var maximumLocalPeak: Double { 0.22 - (strictness * 0.12) }
    var maximumChangedTileFraction: Double { 0.30 - (strictness * 0.17) }
    var maximumChangedRegionTiles: Int { Int((13 - (strictness * 8)).rounded()) }
    var maximumLocalMotion: Double { 0.70 - (strictness * 0.32) }
    var maximumCumulativeMotion: Double { 1.10 - (strictness * 0.66) }

    static let `default` = BurstSimilarityConfiguration(strictness: 0.70)
}

struct SimilarityScanProgress: Sendable {
    let completed: Int
    let total: Int
    let currentFilename: String
}

struct ScanTimings: Sendable {
    let enumeration: TimeInterval
    let previewExtraction: TimeInterval
    let pairAnalysis: TimeInterval
    let total: TimeInterval
}

/// Everything expensive to obtain from a folder. It is retained for one tester
/// session so changing strictness is instantaneous.
struct FolderAnalysis: Sendable {
    let folder: URL
    let cr3Count: Int
    let candidateFrameCount: Int
    let analyzedCount: Int
    let unreadableCount: Int
    let frames: [AnalyzedFrame]
    let adjacentPairs: [AdjacentPairMetric]
    let timings: ScanTimings

    func grouped(using configuration: BurstSimilarityConfiguration) -> [SimilarRun] {
        var groups: [SimilarRun] = []
        var activeFrames: [AnalyzedFrame] = []
        var activePairs: [AdjacentPairMetric] = []
        var cumulativeMotion = 0.0

        func finishActiveGroup() {
            guard activeFrames.count > 1 else { return }
            let averageScene = activePairs.map(\.sceneCorrelation).reduce(0, +) / Double(activePairs.count)
            let maximumLocalMotion = activePairs.map(\.localMotion).max() ?? 0
            let maximumLocalPeak = activePairs.map(\.localPeak).max() ?? 0
            groups.append(
                SimilarRun(
                    frames: activeFrames,
                    averageSceneCorrelation: averageScene,
                    maximumLocalMotion: maximumLocalMotion,
                    maximumLocalPeak: maximumLocalPeak
                )
            )
        }

        for pair in adjacentPairs {
            let passes = pair.isInterchangeable(using: configuration)
            let joinsActiveRun = activeFrames.last.map { $0.frameIndex == pair.fromFrameIndex } ?? false
            let staysWithinMotionBudget = cumulativeMotion + pair.localMotion <= configuration.maximumCumulativeMotion

            if !activeFrames.isEmpty, joinsActiveRun, passes, staysWithinMotionBudget {
                activeFrames.append(frames[pair.toFrameIndex])
                activePairs.append(pair)
                cumulativeMotion += pair.localMotion
                continue
            }

            finishActiveGroup()
            activeFrames.removeAll(keepingCapacity: true)
            activePairs.removeAll(keepingCapacity: true)
            cumulativeMotion = 0

            if passes {
                activeFrames = [frames[pair.fromFrameIndex], frames[pair.toFrameIndex]]
                activePairs = [pair]
                cumulativeMotion = pair.localMotion
            }
        }

        finishActiveGroup()
        return groups
    }
}

struct SimilarityScanResult: Sendable {
    let analysis: FolderAnalysis
    let groups: [SimilarRun]

    var folder: URL { analysis.folder }
    var cr3Count: Int { analysis.cr3Count }
    var analyzedCount: Int { analysis.analyzedCount }
    var unreadableCount: Int { analysis.unreadableCount }
    var timings: ScanTimings { analysis.timings }
}

struct SimilarRun: Identifiable, Sendable {
    let frames: [AnalyzedFrame]
    let averageSceneCorrelation: Double
    let maximumLocalMotion: Double
    let maximumLocalPeak: Double

    var id: URL { frames[0].url }
    var suggestedKeeper: AnalyzedFrame? { frames.max(by: { $0.sharpness < $1.sharpness }) }
    var title: String {
        guard let first = frames.first, let last = frames.last else { return "Interchangeable frames" }
        return first.filename == last.filename ? first.filename : "\(first.filename) – \(last.filename)"
    }
}

struct AnalyzedFrame: Identifiable, Sendable, Hashable {
    let frameIndex: Int
    let url: URL
    let filename: String
    let sequenceNumber: Int
    let sharpness: Double

    var id: URL { url }
}

/// Global scene overlap and local subject motion are intentionally separate;
/// neither is presented as a misleading all-purpose similarity percentage.
struct AdjacentPairMetric: Sendable {
    let fromFrameIndex: Int
    let toFrameIndex: Int
    let sceneCorrelation: Double
    let hashDistance: Int
    let localPeak: Double
    let changedTileFraction: Double
    let largestChangedRegionTiles: Int
    let localMotion: Double

    func isInterchangeable(using configuration: BurstSimilarityConfiguration) -> Bool {
        sceneCorrelation >= configuration.minimumSceneCorrelation
            && hashDistance <= configuration.maximumHashDistance
            && localPeak <= configuration.maximumLocalPeak
            && changedTileFraction <= configuration.maximumChangedTileFraction
            && largestChangedRegionTiles <= configuration.maximumChangedRegionTiles
            && localMotion <= configuration.maximumLocalMotion
    }
}

enum BurstSimilarityEngine {
    private static let coarseSide = 64
    private static let detailSide = 192
    private static let previewSide = 640
    private static let fullPreviewSide = 16_384

    static func scan(
        folder: URL,
        workerCount: Int,
        progress: @escaping @Sendable (SimilarityScanProgress) -> Void
    ) async throws -> FolderAnalysis {
        let started = Date()
        let enumerationStarted = Date()
        let directoryURLs = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let cr3URLs = directoryURLs.filter {
            $0.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame
        }
        let candidates = cr3URLs.compactMap { url -> CandidateFile? in
            guard let number = sequenceNumber(in: url) else { return nil }
            return CandidateFile(url: url, filename: url.lastPathComponent, sequenceNumber: number)
        }
        .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        let candidateRuns = consecutiveRuns(in: candidates)
        let scheduledFiles = candidateRuns.enumerated().flatMap { runIndex, run in
            run.map { ScheduledCandidate(file: $0, runIndex: runIndex) }
        }
        let candidateFrameCount = scheduledFiles.count
        let enumerationDuration = Date().timeIntervalSince(enumerationStarted)

        let workers = min(max(1, workerCount), max(1, candidateFrameCount))
        let previewStarted = Date()
        let descriptorOutputs = try await extractDescriptors(
            for: scheduledFiles,
            workerCount: workers,
            progress: progress
        )
        let previewDuration = Date().timeIntervalSince(previewStarted)

        var frames: [AnalyzedFrame] = []
        var frameIndexByCandidate = [Int?](repeating: nil, count: scheduledFiles.count)
        for (candidateIndex, output) in descriptorOutputs.enumerated() {
            guard let descriptor = output.descriptor else { continue }
            let file = scheduledFiles[candidateIndex].file
            let frame = AnalyzedFrame(
                frameIndex: frames.count,
                url: file.url,
                filename: file.filename,
                sequenceNumber: file.sequenceNumber,
                sharpness: descriptor.sharpness
            )
            frameIndexByCandidate[candidateIndex] = frame.frameIndex
            frames.append(frame)
        }

        var pairInputs: [PairInput] = []
        for candidateIndex in 1..<scheduledFiles.count {
            let previousCandidate = scheduledFiles[candidateIndex - 1]
            let currentCandidate = scheduledFiles[candidateIndex]
            guard previousCandidate.runIndex == currentCandidate.runIndex,
                  let fromFrameIndex = frameIndexByCandidate[candidateIndex - 1],
                  let toFrameIndex = frameIndexByCandidate[candidateIndex],
                  let fromDescriptor = descriptorOutputs[candidateIndex - 1].descriptor,
                  let toDescriptor = descriptorOutputs[candidateIndex].descriptor else { continue }
            pairInputs.append(
                PairInput(
                    fromFrameIndex: fromFrameIndex,
                    toFrameIndex: toFrameIndex,
                    fromDescriptor: fromDescriptor,
                    toDescriptor: toDescriptor
                )
            )
        }

        let pairStarted = Date()
        let pairs = try await measurePairs(pairInputs, workerCount: workers)
        let comparisonDuration = Date().timeIntervalSince(pairStarted)
        return FolderAnalysis(
            folder: folder,
            cr3Count: cr3URLs.count,
            candidateFrameCount: candidateFrameCount,
            analyzedCount: frames.count,
            unreadableCount: candidateFrameCount - frames.count,
            frames: frames,
            adjacentPairs: pairs,
            timings: ScanTimings(
                enumeration: enumerationDuration,
                previewExtraction: previewDuration,
                pairAnalysis: comparisonDuration,
                total: Date().timeIntervalSince(started)
            )
        )
    }

    static func displayThumbnail(for url: URL) -> NSImage? {
        guard let image = thumbnail(for: url, maxPixelSize: previewSide) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Requests the largest embedded preview ImageIO can provide. Canon CR3
    /// files normally carry a high-resolution JPEG preview; this is loaded only
    /// on explicit user request and is never used during the scan.
    static func displayFullResolutionPreview(for url: URL) -> NSImage? {
        guard let image = thumbnail(for: url, maxPixelSize: fullPreviewSide) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func extractDescriptors(
        for files: [ScheduledCandidate],
        workerCount: Int,
        progress: @escaping @Sendable (SimilarityScanProgress) -> Void
    ) async throws -> [DescriptorOutput] {
        guard !files.isEmpty else { return [] }
        let stride = max(1, files.count / 100)
        return try await withThrowingTaskGroup(of: DescriptorOutput.self) { group in
            var nextIndex = 0
            let initialCount = min(workerCount, files.count)
            for index in 0..<initialCount {
                group.addTask {
                    try descriptorOutput(for: files[index], index: index)
                }
                nextIndex = index + 1
            }

            var outputs = [DescriptorOutput?](repeating: nil, count: files.count)
            var completed = 0
            while let output = try await group.next() {
                outputs[output.index] = output
                completed += 1
                if completed == files.count || completed.isMultiple(of: stride) {
                    progress(SimilarityScanProgress(
                        completed: completed,
                        total: files.count,
                        currentFilename: files[output.index].file.filename
                    ))
                }
                if nextIndex < files.count {
                    let index = nextIndex
                    group.addTask {
                        try descriptorOutput(for: files[index], index: index)
                    }
                    nextIndex += 1
                }
            }
            return outputs.compactMap(\.self)
        }
    }

    private static func descriptorOutput(
        for candidate: ScheduledCandidate,
        index: Int
    ) throws -> DescriptorOutput {
        if Task.isCancelled { throw CancellationError() }
        let image = thumbnail(for: candidate.file.url, maxPixelSize: previewSide)
        let descriptor = image.flatMap(makeDescriptor)
        return DescriptorOutput(index: index, descriptor: descriptor)
    }

    private static func measurePairs(
        _ inputs: [PairInput],
        workerCount: Int
    ) async throws -> [AdjacentPairMetric] {
        guard !inputs.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: IndexedPairMetric.self) { group in
            var nextIndex = 0
            let initialCount = min(workerCount, inputs.count)
            for index in 0..<initialCount {
                group.addTask {
                    if Task.isCancelled { throw CancellationError() }
                    return IndexedPairMetric(index: index, metric: pairMetric(for: inputs[index]))
                }
                nextIndex = index + 1
            }

            var metrics = [IndexedPairMetric?](repeating: nil, count: inputs.count)
            while let indexedMetric = try await group.next() {
                metrics[indexedMetric.index] = indexedMetric
                if nextIndex < inputs.count {
                    let index = nextIndex
                    group.addTask {
                        if Task.isCancelled { throw CancellationError() }
                        return IndexedPairMetric(index: index, metric: pairMetric(for: inputs[index]))
                    }
                    nextIndex += 1
                }
            }
            return metrics.compactMap(\.self).map(\.metric)
        }
    }

    private static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func consecutiveRuns(in files: [CandidateFile]) -> [[CandidateFile]] {
        var runs: [[CandidateFile]] = []
        var current: [CandidateFile] = []
        for file in files {
            if let previous = current.last, file.sequenceNumber != previous.sequenceNumber + 1 {
                if current.count > 1 { runs.append(current) }
                current = [file]
            } else {
                current.append(file)
            }
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    private static func sequenceNumber(in url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        let trailingDigits = stem.reversed().prefix(while: { $0.isNumber })
        guard !trailingDigits.isEmpty else { return nil }
        return Int(String(trailingDigits.reversed()))
    }

    private static func makeDescriptor(from image: CGImage) -> FeatureDescriptor? {
        guard let coarse = grayscalePixels(from: image, side: coarseSide),
              let detail = grayscalePixels(from: image, side: detailSide) else { return nil }
        return FeatureDescriptor(
            coarse: coarse,
            detail: detail,
            differenceHash: differenceHash(for: coarse, width: coarseSide),
            sharpness: laplacianVariance(for: coarse, width: coarseSide, height: coarseSide)
        )
    }

    private static func grayscalePixels(from image: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return didDraw ? pixels : nil
    }

    private static func pairMetric(for input: PairInput) -> AdjacentPairMetric {
        let alignment = bestAlignment(
            input.fromDescriptor.coarse,
            input.toDescriptor.coarse,
            width: coarseSide,
            maxShift: 2
        )
        let scale = detailSide / coarseSide
        let local = localDifference(
            input.fromDescriptor.detail,
            input.toDescriptor.detail,
            side: detailSide,
            shiftX: alignment.shiftX * scale,
            shiftY: alignment.shiftY * scale
        )
        return AdjacentPairMetric(
            fromFrameIndex: input.fromFrameIndex,
            toFrameIndex: input.toFrameIndex,
            sceneCorrelation: alignment.correlation,
            hashDistance: (input.fromDescriptor.differenceHash ^ input.toDescriptor.differenceHash).nonzeroBitCount,
            localPeak: local.peak,
            changedTileFraction: local.changedTileFraction,
            largestChangedRegionTiles: local.largestChangedRegionTiles,
            localMotion: local.motion
        )
    }

    private static func differenceHash(for pixels: [UInt8], width: Int) -> UInt64 {
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let sampleY = min((y * width) / 8, width - 1)
                let leftX = min((x * width) / 9, width - 1)
                let rightX = min(((x + 1) * width) / 9, width - 1)
                if pixels[sampleY * width + leftX] > pixels[sampleY * width + rightX] {
                    hash |= UInt64(1) << UInt64(y * 8 + x)
                }
            }
        }
        return hash
    }

    private static func laplacianVariance(for pixels: [UInt8], width: Int, height: Int) -> Double {
        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Double(pixels[y * width + x])
                let laplacian = (4 * center)
                    - Double(pixels[(y - 1) * width + x])
                    - Double(pixels[(y + 1) * width + x])
                    - Double(pixels[y * width + (x - 1)])
                    - Double(pixels[y * width + (x + 1)])
                sum += laplacian
                sumOfSquares += laplacian * laplacian
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, (sumOfSquares / count) - (mean * mean))
    }

    private static func bestAlignment(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        width: Int,
        maxShift: Int
    ) -> Alignment {
        var best = Alignment(correlation: -1, shiftX: 0, shiftY: 0)
        for dy in -maxShift...maxShift {
            for dx in -maxShift...maxShift {
                let minX = max(0, -dx)
                let maxX = min(width, width - dx)
                let minY = max(0, -dy)
                let maxY = min(width, width - dy)
                var count = 0.0
                var sumL = 0.0
                var sumR = 0.0
                var sumLL = 0.0
                var sumRR = 0.0
                var sumLR = 0.0
                for y in minY..<maxY {
                    for x in minX..<maxX {
                        let left = Double(lhs[y * width + x])
                        let right = Double(rhs[(y + dy) * width + (x + dx)])
                        count += 1
                        sumL += left
                        sumR += right
                        sumLL += left * left
                        sumRR += right * right
                        sumLR += left * right
                    }
                }
                let numerator = (count * sumLR) - (sumL * sumR)
                let leftMagnitude = (count * sumLL) - (sumL * sumL)
                let rightMagnitude = (count * sumRR) - (sumR * sumR)
                let denominator = sqrt(max(0, leftMagnitude * rightMagnitude))
                guard denominator > 0 else { continue }
                let correlation = numerator / denominator
                if correlation > best.correlation {
                    best = Alignment(correlation: correlation, shiftX: dx, shiftY: dy)
                }
            }
        }
        return Alignment(correlation: max(0, best.correlation), shiftX: best.shiftX, shiftY: best.shiftY)
    }

    /// The coarse alignment follows static scenery. The detailed residual map
    /// then gives a moving bird, hand, face, or wing a veto over scene overlap.
    private static func localDifference(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        side: Int,
        shiftX: Int,
        shiftY: Int
    ) -> LocalDifference {
        let minX = max(0, -shiftX)
        let maxX = min(side, side - shiftX)
        let minY = max(0, -shiftY)
        let maxY = min(side, side - shiftY)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return .empty }

        var count = 0.0
        var sumL = 0.0
        var sumR = 0.0
        var sumLL = 0.0
        var sumRR = 0.0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let left = Double(lhs[y * side + x])
                let right = Double(rhs[(y + shiftY) * side + (x + shiftX)])
                count += 1
                sumL += left
                sumR += right
                sumLL += left * left
                sumRR += right * right
            }
        }
        let meanL = sumL / count
        let meanR = sumR / count
        let deviationL = sqrt(max(1, (sumLL / count) - (meanL * meanL)))
        let deviationR = sqrt(max(1, (sumRR / count) - (meanR * meanR)))
        let gain = deviationL / deviationR

        let gridSide = 16
        var tileTotals = [Double](repeating: 0, count: gridSide * gridSide)
        var tileCounts = [Int](repeating: 0, count: gridSide * gridSide)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let left = Double(lhs[y * side + x])
                let rawRight = Double(rhs[(y + shiftY) * side + (x + shiftX)])
                let normalizedRight = ((rawRight - meanR) * gain) + meanL
                let difference = min(1, abs(left - normalizedRight) / 255)
                let tileX = min(gridSide - 1, ((x - minX) * gridSide) / width)
                let tileY = min(gridSide - 1, ((y - minY) * gridSide) / height)
                let tileIndex = (tileY * gridSide) + tileX
                tileTotals[tileIndex] += difference
                tileCounts[tileIndex] += 1
            }
        }

        let tileChanges = zip(tileTotals, tileCounts).map { total, tileCount in
            tileCount == 0 ? 0 : total / Double(tileCount)
        }
        let sorted = tileChanges.sorted()
        let baseline = sorted[sorted.count / 2]
        let peak = tileChanges.max() ?? 0
        let topAverage = tileChanges.sorted(by: >).prefix(4).reduce(0, +) / 4
        let changedThreshold = max(0.035, baseline * 2.8)
        let changed = tileChanges.map { $0 > changedThreshold }
        let changedFraction = Double(changed.filter { $0 }.count) / Double(changed.count)
        let largestRegion = largestConnectedRegion(in: changed, gridSide: gridSide)
        let motion = min(1, ((topAverage * 0.70) + (peak * 0.30)) / 0.20)
        return LocalDifference(
            peak: peak,
            changedTileFraction: changedFraction,
            largestChangedRegionTiles: largestRegion,
            motion: motion
        )
    }

    private static func largestConnectedRegion(in changed: [Bool], gridSide: Int) -> Int {
        var visited = [Bool](repeating: false, count: changed.count)
        var largest = 0
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for start in changed.indices where changed[start] && !visited[start] {
            var queue = [start]
            visited[start] = true
            var size = 0
            var cursor = 0
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                size += 1
                let x = current % gridSide
                let y = current / gridSide
                for (dx, dy) in directions {
                    let neighborX = x + dx
                    let neighborY = y + dy
                    guard neighborX >= 0, neighborX < gridSide,
                          neighborY >= 0, neighborY < gridSide else { continue }
                    let neighbor = (neighborY * gridSide) + neighborX
                    if changed[neighbor] && !visited[neighbor] {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }
            largest = max(largest, size)
        }
        return largest
    }
}

private struct CandidateFile: Sendable {
    let url: URL
    let filename: String
    let sequenceNumber: Int
}

private struct ScheduledCandidate: Sendable {
    let file: CandidateFile
    let runIndex: Int
}

private struct DescriptorOutput: Sendable {
    let index: Int
    let descriptor: FeatureDescriptor?
}

private struct PairInput: Sendable {
    let fromFrameIndex: Int
    let toFrameIndex: Int
    let fromDescriptor: FeatureDescriptor
    let toDescriptor: FeatureDescriptor
}

private struct IndexedPairMetric: Sendable {
    let index: Int
    let metric: AdjacentPairMetric
}

private struct FeatureDescriptor: Sendable {
    let coarse: [UInt8]
    let detail: [UInt8]
    let differenceHash: UInt64
    let sharpness: Double
}

private struct Alignment: Sendable {
    let correlation: Double
    let shiftX: Int
    let shiftY: Int
}

private struct LocalDifference: Sendable {
    let peak: Double
    let changedTileFraction: Double
    let largestChangedRegionTiles: Int
    let motion: Double

    static let empty = LocalDifference(peak: 1, changedTileFraction: 1, largestChangedRegionTiles: .max, motion: 1)
}
