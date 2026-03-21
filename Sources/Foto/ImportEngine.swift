import Foundation
import AVFoundation

actor ImportEngine {
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif",
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2",
        "mov", "mp4", "m4v"
    ]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func discoverFiles(in sourceURL: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                files.append(fileURL)
            }
        }
        return files
    }

    func importFiles(
        files: [URL],
        destination: URL,
        mode: TransferMode,
        duplicateChecker: DuplicateChecker,
        progress: ImportProgress
    ) async throws {
        let fm = FileManager.default
        let maxConcurrency = 6

        await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0

            for fileURL in files {
                if Task.isCancelled { break }

                if running >= maxConcurrency {
                    _ = try? await group.next()
                    running -= 1
                }

                group.addTask {
                    try await self.processFile(
                        fileURL: fileURL,
                        destination: destination,
                        mode: mode,
                        duplicateChecker: duplicateChecker,
                        progress: progress,
                        fileManager: fm
                    )
                }
                running += 1
            }
        }
    }

    private func processFile(
        fileURL: URL,
        destination: URL,
        mode: TransferMode,
        duplicateChecker: DuplicateChecker,
        progress: ImportProgress,
        fileManager fm: FileManager
    ) async throws {
        let filename = fileURL.lastPathComponent

        await MainActor.run { progress.currentFile = filename }

        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int else {
            await MainActor.run {
                progress.errors.append((file: filename, message: "Could not read file size"))
                progress.processedFiles += 1
            }
            return
        }

        if await duplicateChecker.isDuplicate(filename: filename, size: fileSize) {
            await MainActor.run {
                progress.duplicatesSkipped += 1
                progress.processedFiles += 1
            }
            return
        }

        guard let dateResult = await EXIFDateReader.readDate(from: fileURL) else {
            await MainActor.run {
                progress.errors.append((file: filename, message: "Could not determine date"))
                progress.processedFiles += 1
            }
            return
        }

        if dateResult.source == .filesystem {
            await MainActor.run {
                progress.fallbackDateFiles.append(filename)
            }
        }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: dateResult.date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)

        let destDir = destination
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent(day)
        let destFile = destDir.appendingPathComponent(filename)

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            var finalDest = destFile
            if fm.fileExists(atPath: finalDest.path) {
                let stem = fileURL.deletingPathExtension().lastPathComponent
                let ext = fileURL.pathExtension
                var counter = 1
                repeat {
                    finalDest = destDir.appendingPathComponent("\(stem)_\(counter).\(ext)")
                    counter += 1
                } while fm.fileExists(atPath: finalDest.path)
            }

            switch mode {
            case .copy:
                try fm.copyItem(at: fileURL, to: finalDest)
            case .move:
                try fm.moveItem(at: fileURL, to: finalDest)
            }

            await duplicateChecker.markImported(filename: filename, size: fileSize)
        } catch {
            await MainActor.run {
                progress.errors.append((file: filename, message: error.localizedDescription))
            }
        }

        await MainActor.run {
            progress.processedFiles += 1
        }
    }
}
