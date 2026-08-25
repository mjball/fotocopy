import AppKit
import SwiftUI

struct BurstCullTesterView: View {
    @State private var model = BurstCullTesterModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)

                if model.isScanning {
                    Button("Cancel") { model.cancel() }
                } else if model.folderURL != nil {
                    Button("Scan Again") { model.scan() }
                        .disabled(model.folderURL == nil)
                }
            }
        }
        .alert("Could not scan folder", isPresented: $model.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .onChange(of: model.strictness) { _, _ in
            model.regroup()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Burst Cull Tester")
                .font(.headline)
            Text("Read-only local analysis. It never moves, tags, or deletes photos.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let folderURL = model.folderURL {
                Label(folderURL.path, systemImage: "folder")
                    .font(.caption)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("Choose one destination folder containing CR3 files.")
                    .foregroundStyle(.secondary)
            }

            strictnessControl
            workerControl

            if model.isScanning {
                ProgressView(value: Double(model.progressCompleted), total: Double(max(model.progressTotal, 1))) {
                    Text("Analysing \(model.progressCompleted) / \(model.progressTotal)")
                } currentValueLabel: {
                    Text(model.currentFilename)
                        .lineLimit(1)
                }
                .font(.caption)
            }

            if let result = model.result {
                scanSummary(result)
                Divider()
                List(selection: $model.selectedGroupID) {
                    Section("Interchangeable near-duplicates") {
                        ForEach(result.groups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.title)
                                    .lineLimit(1)
                                Text("\(group.frames.count) frames · local motion within current limit")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(group.id)
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Spacer()

            Button("Reveal Folder in Finder") { model.revealFolder() }
                .disabled(model.folderURL == nil)
        }
        .padding(16)
        .frame(minWidth: 310)
    }

    private var strictnessControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Similarity strictness")
                Spacer()
                Text(model.strictnessLabel)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: $model.strictness, in: 0...1, step: 0.05)
                .disabled(model.isScanning)
            Text("Updates the displayed runs instantly from this scan's cached measurements.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var workerControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scan workers")
                .font(.caption)
            Picker("Scan workers", selection: $model.scanWorkerCount) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("4").tag(4)
                Text("6").tag(6)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(model.isScanning)
            Text("Parallel preview decodes and local comparisons. Try 2 if BAR is a spinning drive; 4 is the default.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func scanSummary(_ result: SimilarityScanResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(result.groups.count) suggested run\(result.groups.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.semibold))
            Text("\(result.analyzedCount) of \(result.cr3Count) CR3s analysed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(result.timings.previewExtraction.formatted(.number.precision(.fractionLength(1))))s previews · \(result.timings.pairAnalysis.formatted(.number.precision(.fractionLength(1))))s comparisons · \(model.scanWorkerCount) workers")
                .font(.caption)
                .foregroundStyle(.secondary)
            if result.unreadableCount > 0 {
                Text("\(result.unreadableCount) previews could not be read")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.isScanning {
            ContentUnavailableView(
                "Analysing consecutive CR3 runs",
                systemImage: "sparkles",
                description: Text("Only adjacent filenames are compared. Original files stay untouched.")
            )
        } else if let group = model.selectedGroup {
            SimilarRunReviewView(group: group, model: model)
        } else if model.result != nil {
            ContentUnavailableView(
                "No similar run selected",
                systemImage: "rectangle.stack",
                description: Text("Choose a suggested run from the sidebar.")
            )
        } else {
            ContentUnavailableView(
                "Choose a destination folder",
                systemImage: "folder.badge.magnifyingglass",
                description: Text("The tester finds near-identical images only among consecutive CR3 filenames in that one folder.")
            )
        }
    }
}

private struct SimilarRunReviewView: View {
    let group: SimilarRun
    @Bindable var model: BurstCullTesterModel
    @State private var fullPreviewURL: URL?
    @State private var isShowingFullPreview = false

    private var selectedFrame: AnalyzedFrame? {
        group.frames.first { $0.url == model.selectedFrameURL }
            ?? group.suggestedKeeper
            ?? group.frames.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.title3.weight(.semibold))
                    Text("\(group.frames.count) consecutive frames · stable scene and no large local movement at this setting")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal Selected") { model.revealSelectedFrame() }
                    .disabled(selectedFrame == nil)
            }

            if let selectedFrame {
                HStack(alignment: .top, spacing: 18) {
                    RawThumbnailView(url: selectedFrame.url)
                        .frame(minWidth: 430, minHeight: 390)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(selectedFrame.filename)
                            .font(.headline)
                        if selectedFrame.url == group.suggestedKeeper?.url {
                            Label("Suggested sharpest frame", systemImage: "scope")
                                .foregroundStyle(.blue)
                        }
                        Text("Sharpness score: \(selectedFrame.sharpness, format: .number.precision(.fractionLength(0)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Worst local change in this run: \(group.maximumLocalPeak, format: .percent.precision(.fractionLength(0)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Button(model.isKeeper(selectedFrame.url) ? "Marked as keeper" : "Mark as keeper") {
                            model.toggleKeeper(selectedFrame.url)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Inspect full JPEG…") {
                            fullPreviewURL = selectedFrame.url
                            isShowingFullPreview = true
                        }

                        Text("This is a temporary tester selection only. It is not written to the folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 220, alignment: .leading)
                }
            }

            HStack {
                Text("Frames")
                    .font(.headline)
                Spacer()
                Button("Use sharpest suggestion") { model.useSuggestedKeeper(for: group) }
                Button("Keep all") { model.markAllKeepers(in: group) }
                Button("Clear this run") { model.clearKeepers(in: group) }
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.frames) { frame in
                        Button {
                            model.selectedFrameURL = frame.url
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                RawThumbnailView(url: frame.url)
                                    .frame(width: 128, height: 96)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(model.selectedFrameURL == frame.url ? Color.accentColor : Color.clear, lineWidth: 3)
                                    }
                                Text(frame.filename)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    if frame.url == group.suggestedKeeper?.url {
                                        Image(systemName: "scope")
                                            .foregroundStyle(.blue)
                                    }
                                    if model.isKeeper(frame.url) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .frame(height: 14)
                            }
                            .frame(width: 128, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(frame.filename)
                    }
                }
                .padding(.bottom, 4)
            }

            Spacer()

            HStack {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text("Read-only tester: it does not save selections, move files, tag Finder items, or delete anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .task(id: group.id) {
            await Task.detached(priority: .utility) {
                RawThumbnailCache.shared.prefetch(group.frames.map(\.url))
            }.value
        }
        .sheet(isPresented: $isShowingFullPreview, onDismiss: { fullPreviewURL = nil }) {
            if let fullPreviewURL {
                FullResolutionPreviewSheet(url: fullPreviewURL)
            }
        }
    }
}

private struct RawThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            let rendered = await Task.detached(priority: .userInitiated) {
                RawThumbnailCache.shared.thumbnail(for: url)
            }.value
            image = rendered
            failed = rendered == nil
        }
    }
}

private final class RawThumbnailCache: @unchecked Sendable {
    static let shared = RawThumbnailCache()

    private let images = NSCache<NSURL, NSImage>()

    private init() {
        images.countLimit = 72
        images.totalCostLimit = 120 * 1_024 * 1_024
    }

    func thumbnail(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = images.object(forKey: key) { return cached }
        guard let image = BurstSimilarityEngine.displayThumbnail(for: url) else { return nil }
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        images.setObject(image, forKey: key, cost: cost)
        return image
    }

    func prefetch(_ urls: [URL]) {
        for url in urls {
            _ = thumbnail(for: url)
        }
    }
}

private struct FullResolutionPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                    Text("Largest embedded JPEG preview · 100% means original preview pixels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            Group {
                if let image {
                    ZoomableFullPreview(image: image)
                } else if failed {
                    ContentUnavailableView(
                        "Full preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("ImageIO could not produce a larger embedded preview for this file."))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading full embedded JPEG preview…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 900, minHeight: 650)
        }
        .task(id: url) {
            image = nil
            failed = false
            let rendered = await Task.detached(priority: .userInitiated) {
                FullResolutionPreviewCache.shared.preview(for: url)
            }.value
            image = rendered
            failed = rendered == nil
        }
    }
}

private struct ZoomableFullPreview: View {
    let image: NSImage
    @State private var zoom = 0.25

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Zoom \(zoom, format: .percent.precision(.fractionLength(0)))")
                    .monospacedDigit()
                    .frame(width: 90, alignment: .leading)
                Slider(value: $zoom, in: 0.05...1.0, step: 0.05)
                Button("25%") { zoom = 0.25 }
                Button("100%") { zoom = 1.0 }
            }
            .padding(12)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: max(1, image.size.width * zoom),
                        height: max(1, image.size.height * zoom)
                    )
                    .padding(20)
            }
            .background(.black.opacity(0.88))
        }
    }
}

private final class FullResolutionPreviewCache: @unchecked Sendable {
    static let shared = FullResolutionPreviewCache()

    private let images = NSCache<NSURL, NSImage>()

    private init() {
        images.countLimit = 1
        images.totalCostLimit = 300 * 1_024 * 1_024
    }

    func preview(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = images.object(forKey: key) { return cached }
        guard let image = BurstSimilarityEngine.displayFullResolutionPreview(for: url) else { return nil }
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        images.setObject(image, forKey: key, cost: cost)
        return image
    }
}

@Observable
@MainActor
final class BurstCullTesterModel {
    var folderURL: URL?
    var strictness = BurstSimilarityConfiguration.default.strictness
    var scanWorkerCount = 4
    var result: SimilarityScanResult?
    var isScanning = false
    var progressCompleted = 0
    var progressTotal = 0
    var currentFilename = ""
    var errorMessage: String?
    var showError = false
    var selectedGroupID: URL?
    var selectedFrameURL: URL?
    private(set) var keepers: Set<URL> = []

    private var analysis: FolderAnalysis?
    private var scanTask: Task<Void, Never>?

    var strictnessLabel: String {
        switch strictness {
        case 0..<0.35: return "Permissive"
        case 0.35..<0.75: return "Balanced"
        default: return "Strict"
        }
    }

    var selectedGroup: SimilarRun? {
        result?.groups.first { $0.id == selectedGroupID }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose one destination folder containing CR3 photos. No files will be modified."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderURL = url
        scan()
    }

    func scan() {
        guard let folderURL, !isScanning else { return }
        scanTask?.cancel()
        result = nil
        analysis = nil
        keepers.removeAll()
        selectedGroupID = nil
        selectedFrameURL = nil
        isScanning = true
        progressCompleted = 0
        progressTotal = 0
        currentFilename = "Preparing scan…"
        errorMessage = nil
        let model = self
        let workerCount = scanWorkerCount

        scanTask = Task {
            do {
                let folderAnalysis = try await Task.detached(priority: .userInitiated) {
                    try await BurstSimilarityEngine.scan(folder: folderURL, workerCount: workerCount) { progress in
                        Task { @MainActor in
                            model.progressCompleted = progress.completed
                            model.progressTotal = progress.total
                            model.currentFilename = progress.currentFilename
                        }
                    }
                }.value

                guard !Task.isCancelled else { return }
                analysis = folderAnalysis
                regroup()
            } catch is CancellationError {
                // The next scan replaces this one; no user-facing error is needed.
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isScanning = false
            scanTask = nil
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentFilename = "Cancelled"
    }

    /// Applies new grouping thresholds to cached pair metrics. No CR3 is read.
    func regroup() {
        guard let analysis else { return }
        let configuration = BurstSimilarityConfiguration(strictness: strictness)
        let groups = analysis.grouped(using: configuration)
        result = SimilarityScanResult(analysis: analysis, groups: groups)

        if let selectedGroupID,
           let selectedGroup = groups.first(where: { $0.id == selectedGroupID }) {
            if !selectedGroup.frames.contains(where: { $0.url == selectedFrameURL }) {
                selectedFrameURL = selectedGroup.suggestedKeeper?.url
            }
        } else {
            selectedGroupID = groups.first?.id
            selectedFrameURL = groups.first?.suggestedKeeper?.url
        }
    }

    func isKeeper(_ url: URL) -> Bool {
        keepers.contains(url)
    }

    func toggleKeeper(_ url: URL) {
        if keepers.contains(url) {
            keepers.remove(url)
        } else {
            keepers.insert(url)
        }
    }

    func useSuggestedKeeper(for group: SimilarRun) {
        clearKeepers(in: group)
        if let suggested = group.suggestedKeeper {
            keepers.insert(suggested.url)
            selectedFrameURL = suggested.url
        }
    }

    func markAllKeepers(in group: SimilarRun) {
        keepers.formUnion(group.frames.map(\.url))
    }

    func clearKeepers(in group: SimilarRun) {
        keepers.subtract(group.frames.map(\.url))
    }

    func revealFolder() {
        guard let folderURL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderURL.path)
    }

    func revealSelectedFrame() {
        guard let selectedFrameURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedFrameURL])
    }
}
