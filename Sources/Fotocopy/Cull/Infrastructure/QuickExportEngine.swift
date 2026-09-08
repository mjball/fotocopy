import Foundation

/// A small, file-first JPEG export path for Cull. `sips` is Apple's supported
/// command-line front end for ImageIO, which gives Fotocopy the same native
/// image conversion stack used throughout macOS without asking the user to
/// first move their RAW files into another application.
struct QuickExportPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let sourceURL: URL
        let destinationURL: URL
    }

    let destinationFolderURL: URL
    let items: [Item]
}

struct QuickExportFailure: Sendable, Equatable {
    let sourceURL: URL
    let message: String
}

struct QuickExportResult: Sendable, Equatable {
    let exportedURLs: [URL]
    let failures: [QuickExportFailure]
}

enum QuickExportError: LocalizedError, Equatable {
    case noPhotosSelected
    case destinationIsNotFolder(URL)
    case destinationAlreadyExists(URL)
    case sourceDoesNotExist(URL)

    var errorDescription: String? {
        switch self {
        case .noPhotosSelected:
            "Select at least one photo to export."
        case let .destinationIsNotFolder(url):
            "\(url.path) is not a folder."
        case let .destinationAlreadyExists(url):
            "Fotocopy will not overwrite an existing export: \(url.lastPathComponent)"
        case let .sourceDoesNotExist(url):
            "The selected photo is no longer available: \(url.lastPathComponent)"
        }
    }
}

enum QuickExportEngine {
    static func makePlan(
        sourceURLs: [URL],
        destinationFolderURL: URL,
        fileManager: FileManager = .default
    ) throws -> QuickExportPlan {
        let sources = uniqueStandardizedURLs(sourceURLs)
        guard !sources.isEmpty else { throw QuickExportError.noPhotosSelected }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationFolderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw QuickExportError.destinationIsNotFolder(destinationFolderURL)
        }

        let items = try sources.map { sourceURL in
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw QuickExportError.sourceDoesNotExist(sourceURL)
            }
            let destinationURL = destinationFolderURL
                .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("jpg")
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                throw QuickExportError.destinationAlreadyExists(destinationURL)
            }
            return QuickExportPlan.Item(sourceURL: sourceURL, destinationURL: destinationURL)
        }

        return QuickExportPlan(destinationFolderURL: destinationFolderURL, items: items)
    }

    /// Export every item independently so one malformed RAW does not discard
    /// successfully converted neighbouring frames. A second collision check
    /// immediately before `sips` protects files created after folder choice.
    static func export(
        _ plan: QuickExportPlan,
        fileManager: FileManager = .default,
        runConverter: (URL, URL) throws -> Void = convertWithSips
    ) -> QuickExportResult {
        var exportedURLs: [URL] = []
        var failures: [QuickExportFailure] = []

        for item in plan.items {
            do {
                guard !fileManager.fileExists(atPath: item.destinationURL.path) else {
                    throw QuickExportError.destinationAlreadyExists(item.destinationURL)
                }
                try runConverter(item.sourceURL, item.destinationURL)
                exportedURLs.append(item.destinationURL)
            } catch {
                failures.append(QuickExportFailure(
                    sourceURL: item.sourceURL,
                    message: error.localizedDescription
                ))
            }
        }

        return QuickExportResult(exportedURLs: exportedURLs, failures: failures)
    }

    private static func convertWithSips(sourceURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        // `sips` uses ImageIO's macOS RAW support and keeps the conversion
        // native. Supplying URLs as Process arguments avoids shell expansion
        // for camera filenames containing spaces or punctuation.
        process.arguments = ["-s", "format", "jpeg", sourceURL.path, "--out", destinationURL.path]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConverterError(details?.isEmpty == false ? details! : "macOS could not convert this image to JPEG.")
        }
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return seen.insert(standardized).inserted ? standardized : nil
        }
    }

    private struct ConverterError: LocalizedError {
        let details: String
        var errorDescription: String? { details }

        init(_ details: String) {
            self.details = details
        }
    }
}
