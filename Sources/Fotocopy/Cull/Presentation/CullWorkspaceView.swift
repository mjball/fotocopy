import AppKit
import ImageIO
import SwiftUI

struct CullWorkspaceView: View {
    @Bindable var model: CullViewModel
    @Binding var layout: CullReviewLayout

    var body: some View {
        detail
        .background {
            if model.selectedReviewGroup != nil {
                CullNavigationKeyHandler(
                    moveFrame: { model.moveSelectedReviewFrame(by: $0) },
                    moveBurst: { model.moveSelectedReviewGroup(by: $0) },
                    keepCurrentFrame: { model.keepSelectedFrame() },
                    keepCurrentAndRejectRest: {
                        guard let burst = model.selectedBurst else { return }
                        model.keepSelectedAndRejectRest(in: burst)
                    },
                    rejectCurrentFrame: { model.rejectSelectedFrame() },
                    rejectBurst: {
                        guard let burst = model.selectedBurst else { return }
                        model.markAllRejecting(in: burst)
                    }
                )
                .frame(width: 0, height: 0)
            }
        }
        .task {
            model.resumeLastScanIfNeeded()
            model.library.refreshImageStatisticsIfNeeded()
        }
        .alert("Could not scan folder", isPresented: $model.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .alert("Could not move cull frame", isPresented: $model.showMoveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.moveErrorMessage ?? "Unknown error")
        }
        .alert(model.quickExportAlertTitle, isPresented: $model.showQuickExportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.quickExportAlertMessage)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.isScanning {
            ContentUnavailableView(
                "Finding photos",
                systemImage: "rectangle.stack.badge.play",
                description: Text("Fotocopy reads this date folder plus Keeps and Rejects, then rebuilds burst and single-frame review from the files on disk."))
        } else if let burst = model.selectedBurst {
            BurstReviewView(burst: burst, model: model, layout: layout)
        } else if model.isReviewingSingles, let frame = model.selectedSingleFrame {
            SingleFrameReviewView(frame: frame, model: model, layout: layout)
        } else if model.isReviewingSingles, model.scanResult != nil {
            SingleFrameReviewEmptyState(model: model, layout: layout)
        } else if let scan = model.scanResult, scan.cr3Count == 0 {
            ContentUnavailableView(
                "No CR3 files in this folder",
                systemImage: "camera.metering.none",
                description: Text("Cull looks for CR3 files in this destination date folder, plus its Keeps and Rejects subfolders."))
        } else if let scan = model.scanResult, scan.bursts.isEmpty, scan.singleFrames.isEmpty {
            ContentUnavailableView(
                "No photos found for review",
                systemImage: "rectangle.stack",
                description: Text("Fotocopy found no CR3 files it can group or review in this date folder."))
        } else if let scan = model.scanResult, scan.bursts.isEmpty {
            ContentUnavailableView(
                "Single frames ready",
                systemImage: "photo.on.rectangle",
                description: Text("Select Review single frames in the sidebar to keep or reject the \(scan.singleFrames.count) standalone \(scan.singleFrames.count == 1 ? "photo" : "photos")."))
        } else {
            ContentUnavailableView(
                "Choose a destination folder",
                systemImage: "folder.badge.magnifyingglass",
                description: Text("It will group consecutive CR3 captures and queue standalone photos for manual review, without creating a library."))
        }
    }

}

/// The single-frame filter remains visible after a focused queue is exhausted,
/// so a photographer can immediately revisit the decisions they just made.
private struct SingleFrameReviewEmptyState: View {
    @Bindable var model: CullViewModel
    let layout: CullReviewLayout

    var body: some View {
        Group {
            switch layout {
            case .browse:
                VStack(alignment: .leading, spacing: 16) {
                    standardHeader
                    Spacer()
                    emptyState
                    Spacer()
                }
                .padding(24)
            case .review:
                VStack(spacing: 10) {
                    compactHeader
                    Spacer()
                    emptyState
                    Spacer()
                }
                .padding(.vertical, 12)
            case .focus:
                ZStack {
                    Color.black
                    VStack(spacing: 0) {
                        compactHeader
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                            .background(
                                LinearGradient(
                                    colors: [.black.opacity(0.76), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Spacer()
                        emptyState
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var progressLabel: String {
        "\(model.scanResult?.singleFrames.count ?? 0) frames · \(model.undecidedSingleFrameCount) undecided"
    }

    private var standardHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Single frames")
                    .font(.title3.weight(.semibold))
                Text(progressLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SingleFrameFilterPicker(model: model)
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Single frames")
                    .font(.headline)
                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SingleFrameFilterPicker(model: model)
        }
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No \(model.singleFrameFilter.title.lowercased()) single frames",
            systemImage: "checkmark.circle",
            description: Text("Choose another filter above to revisit your decisions, or rescan after changing files in Finder."))
    }
}

private struct SingleFrameFilterPicker: View {
    @Bindable var model: CullViewModel

    var body: some View {
        Picker("Single-frame filter", selection: $model.singleFrameFilter) {
            ForEach(SingleFrameReviewFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .onChange(of: model.singleFrameFilter) {
            model.selectFirstSingleFrameMatchingFilter()
        }
    }
}

/// These sections live in Fotocopy's single app sidebar. Keeping the burst
/// tools here avoids a second, mode-specific split view and keeps workspace
/// navigation fixed while changing between Import and Cull.
struct CullSidebarSections: View {
    @Bindable var model: CullViewModel

    var body: some View {
        Section("Cull") {
            if let folder = model.folderURL {
                Label(folder.path, systemImage: "folder")
                    .lineLimit(2)
                    .help(folder.path)
            } else {
                Text("Choose a destination folder containing CR3 photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sourcePickerControls
        }

        if model.isScanning {
            Section("Scanning") {
                ProgressView(
                    value: Double(model.progressCompleted),
                    total: Double(max(model.progressTotal, 1))
                ) {
                    Text("Reading capture times")
                } currentValueLabel: {
                    Text(model.currentFilename)
                        .lineLimit(1)
                }
                .font(.caption)
            }
        }

        if let scan = model.scanResult {
            Section {
                scanSummary(scan)
            }

            if !scan.bursts.isEmpty {
                Section("Bursts") {
                    ForEach(scan.bursts) { burst in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(burst.title)
                                    .lineLimit(1)
                                Text("\(burst.frames.count) frames · \(captureRangeLabel(for: burst))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if let status = burst.decisionStatus {
                                BurstDecisionStatusIcon(status: status)
                            }
                        }
                        .tag(FotocopySidebarDestination.burst(burst.id))
                        .id(FotocopySidebarDestination.burst(burst.id))
                    }
                }
            }

            if !scan.singleFrames.isEmpty {
                Section("Single frames") {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Review single frames")
                            Text(singleFrameSummary(scan))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if model.undecidedSingleFrameCount == 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("All single frames reviewed")
                        }
                    }
                    .tag(FotocopySidebarDestination.singleFrames)
                    .id(FotocopySidebarDestination.singleFrames)
                }
            }
        }

        if model.folderURL != nil {
            Section {
                Button("Reveal Folder in Finder") { model.revealFolder() }
            }
        }
    }

    @ViewBuilder
    private var sourcePickerControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                recentImportMenu
                chooseFolderButton
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 8) {
                recentImportMenu
                chooseFolderButton
            }
        }
    }

    private var recentImportMenu: some View {
        Menu("Recent Import") {
            if model.recentImportedFolders.isEmpty {
                Text("No completed Fotocopy import yet")
            } else {
                ForEach(model.recentImportedFolders, id: \.path) { folder in
                    Button(folder.path) { model.requestUse(folder: folder) }
                }
            }
        }
        .controlSize(.small)
        .disabled(model.isScanning || model.isMoving)
    }

    private var chooseFolderButton: some View {
        Button("Choose Folder…") { model.chooseFolder() }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(model.isScanning || model.isMoving)
    }

    private func scanSummary(_ scan: CullFolderScan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(scan.bursts.count) burst\(scan.bursts.count == 1 ? "" : "s") found")
                .font(.subheadline.weight(.semibold))
            Text("\(scan.cr3Count) CR3s · \(scan.duration.formatted(.number.precision(.fractionLength(1))))s")
                .font(.caption)
                .foregroundStyle(.secondary)
            if scan.unreadableMetadataCount > 0 {
                Text("\(scan.unreadableMetadataCount) files lacked readable capture time")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func captureRangeLabel(for burst: PhotoBurst) -> String {
        let range = burst.captureRange
        guard let start = range.start else { return "sequence only" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        if let end = range.end, end != start {
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
        return formatter.string(from: start)
    }

    private func singleFrameSummary(_ scan: CullFolderScan) -> String {
        let total = scan.singleFrames.count
        let undecided = model.undecidedSingleFrameCount
        return "\(total) \(total == 1 ? "frame" : "frames") · \(undecided) undecided"
    }
}

/// An outline means a burst still has undecided frames; a filled glyph means
/// the burst is complete. The green check wins once a burst has a keeper, so
/// the sidebar stays legible without showing multiple status icons per row.
private struct BurstDecisionStatusIcon: View {
    let status: BurstDecisionStatus

    private var systemImage: String {
        switch status {
        case .keepingInProgress:
            "checkmark.circle"
        case .rejectingInProgress:
            "xmark.circle"
        case .kept:
            "checkmark.circle.fill"
        case .rejected:
            "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .keepingInProgress, .kept:
            .green
        case .rejectingInProgress, .rejected:
            .red
        }
    }

    private var accessibilityDescription: String {
        switch status {
        case .keepingInProgress:
            "In progress: at least one frame kept"
        case .rejectingInProgress:
            "In progress: frames rejected, no frame kept yet"
        case .kept:
            "Reviewed: at least one frame kept"
        case .rejected:
            "Reviewed: every frame rejected"
        }
    }

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityDescription)
            .help(accessibilityDescription)
    }
}

/// A single-frame review deliberately keeps the familiar cull viewer while
/// omitting burst semantics. The active filter is a queue: Keep and Reject
/// advance to the next matching frame, while revisiting Keeps or Rejects still
/// allows a decision to be cleared.
private struct SingleFrameReviewView: View {
    let frame: CullPhoto
    @Bindable var model: CullViewModel
    let layout: CullReviewLayout
    @AppStorage(PreferenceKeys.cullPreviewHeight) private var previewHeight = 540.0
    @AppStorage(PreferenceKeys.cullShowsAFTarget) private var showsCameraAFTarget = true
    @State private var previewHeightAtDragStart: Double?
    @State private var viewport = CullPreviewViewport()

    private let defaultPreviewHeight = 540.0
    private let minimumPreviewHeight = 360.0
    private let maximumPreviewHeight = 1_200.0

    private var visibleFrames: [CullPhoto] { model.filteredSingleFrames }

    private var framePosition: Int {
        (visibleFrames.firstIndex { $0.url == frame.url } ?? 0) + 1
    }

    private var progressLabel: String {
        "\(framePosition) of \(visibleFrames.count) · \(model.undecidedSingleFrameCount) undecided"
    }

    var body: some View {
        Group {
            switch layout {
            case .browse:
                ScrollView { browseContent }
            case .review:
                compactContent
            case .focus:
                focusContent
            }
        }
        .onChange(of: frame.url) { viewport = CullPreviewViewport() }
        .task(id: frame.url) {
            model.loadCameraAFTarget(for: frame)
            await Task.detached(priority: .utility) {
                CullPreviewCache.shared.prefetch([frame.url])
            }.value
        }
    }

    private var browseContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            standardHeader
            HStack(alignment: .top, spacing: 18) {
                preview
                    .frame(maxWidth: .infinity, minHeight: resolvedPreviewHeight, maxHeight: resolvedPreviewHeight)
                inspector(height: resolvedPreviewHeight)
            }
            CullPreviewHeightResizeHandle(
                onChanged: resizePreview,
                onEnded: { previewHeightAtDragStart = nil },
                onReset: {
                    previewHeight = defaultPreviewHeight
                    previewHeightAtDragStart = nil
                }
            )
            filmstrip
            moveStatus
        }
        .padding(24)
    }

    private var compactContent: some View {
        VStack(spacing: 10) {
            compactHeader
            preview
                .padding(.horizontal, 14)
            filmstrip
        }
        .padding(.vertical, 12)
    }

    private var focusContent: some View {
        ZStack(alignment: .bottom) {
            preview
                .clipShape(Rectangle())
            VStack(spacing: 0) {
                compactHeader
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0.76), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Spacer()
                filmstrip
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.68))
            }
        }
    }

    private var standardHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Single frames")
                    .font(.title3.weight(.semibold))
                Text(progressLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            filterPicker
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(frame.filename)
                    .font(.headline)
                    .lineLimit(1)
                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            filterPicker
            compactDecisionControls
        }
        .padding(.horizontal, 16)
    }

    private var filterPicker: some View {
        SingleFrameFilterPicker(model: model)
    }

    private var preview: some View {
        CullInspectionPreviewView(
            url: frame.url,
            inspectionPoint: model.inspectionPoint,
            cameraAFTarget: showsCameraAFTarget ? model.cameraAFTarget(for: frame.url) : nil,
            isPickingInspectionPoint: model.isPickingInspectionPoint,
            onInspectionPointSelected: model.setInspectionPoint,
            viewport: $viewport
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 10))
    }

    private func inspector(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorHeader

            Divider()
            decisionControls

            Divider()
            focusSection

            Spacer(minLength: 8)
            safetyHint
            CullLibraryStatisticsInspector(library: model.library)
        }
        .frame(width: 230, alignment: .leading)
        .frame(minHeight: height, maxHeight: height, alignment: .topLeading)
    }

    @ViewBuilder
    private var decisionControls: some View {
        HStack(spacing: 7) {
            Button(model.isKeeping(frame.url) ? "Kept" : "Keep") {
                model.isKeeping(frame.url) ? model.clearSelectedFrameDisposition() : model.keepSelectedFrame()
            }
            .buttonStyle(.borderedProminent)

            Button(model.isRejecting(frame.url) ? "Rejected" : "Reject") {
                model.isRejecting(frame.url) ? model.clearSelectedFrameDisposition() : model.rejectSelectedFrame()
            }
            .buttonStyle(.bordered)

            if model.canUndoLastMove {
                Button { model.undoLastMove() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .help("Undo latest cull move")
                .accessibilityLabel("Undo latest cull move")
            }
        }
        .disabled(model.isMoving)
    }

    private var inspectorHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(frame.filename)
                    .font(.headline)
                    .lineLimit(1)
                Text(captureLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { model.revealSelectedFrame() } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal selected photo in Finder")
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Focus")
                .font(.caption.weight(.semibold))
            focusStatus

            Button(model.isPickingInspectionPoint ? "Cancel picking" : "Pick detail…") {
                if model.isPickingInspectionPoint {
                    model.cancelPickingInspectionPoint()
                } else {
                    model.beginPickingInspectionPoint()
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            if shouldOfferCameraAF {
                Button("Use AF target") { model.useCameraAFTarget() }
                    .buttonStyle(.link)
                    .help("Use camera AF target")
                    .accessibilityLabel("Use camera AF target")
            } else if shouldOfferManualClear {
                Button("Clear focus point") { model.clearInspectionPoint() }
                    .buttonStyle(.link)
            }
        }
    }

    private var safetyHint: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Keep and Reject move the raw and its sidecars immediately. Undo returns the latest move; nothing is deleted.")
            .accessibilityLabel("Keep and Reject move the raw and its sidecars immediately. Undo returns the latest move; nothing is deleted.")
    }

    @ViewBuilder
    private var focusStatus: some View {
        if model.isPickingInspectionPoint {
            Label("Choose a detail in the preview", systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.inspectionPoint != nil {
            Label("Manual focus point", systemImage: "circle.inset.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        } else if model.isLoadingCameraAFTarget(for: frame.url) {
            Label("Reading camera AF data…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let target = model.cameraAFTarget(for: frame.url) {
            HStack(spacing: 6) {
                Label("Camera AF target", systemImage: "viewfinder")
                Spacer(minLength: 0)
                Label(target.state.displayName, systemImage: "circle.fill")
                    .foregroundStyle(target.state == .focused ? .green : .secondary)
            }
            .font(.caption.weight(.semibold))
        } else if model.hasLoadedCameraAFTarget(for: frame.url) {
            Text("No active camera AF target recorded")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shouldOfferCameraAF: Bool {
        !model.isPickingInspectionPoint &&
            !model.isUsingCameraAFTarget &&
            model.cameraAFTarget(for: frame.url) != nil
    }

    private var shouldOfferManualClear: Bool {
        !model.isPickingInspectionPoint &&
            model.inspectionPoint != nil &&
            model.cameraAFTarget(for: frame.url) == nil
    }

    private var compactDecisionControls: some View {
        HStack(spacing: 7) {
            Button(model.isKeeping(frame.url) ? "Kept" : "Keep") {
                model.isKeeping(frame.url) ? model.clearSelectedFrameDisposition() : model.keepSelectedFrame()
            }
            .buttonStyle(.borderedProminent)

            Button(model.isRejecting(frame.url) ? "Rejected" : "Reject") {
                model.isRejecting(frame.url) ? model.clearSelectedFrameDisposition() : model.rejectSelectedFrame()
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .disabled(model.isMoving)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(visibleFrames) { candidate in
                        Button {
                            model.selectSingleFrame(
                                candidate.url,
                                extendingQuickExportSelection: NSEvent.modifierFlags.contains(.command),
                                selectingQuickExportRange: NSEvent.modifierFlags.contains(.shift)
                            )
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                CullPreviewView(url: candidate.url, size: .thumbnail)
                                    .frame(width: 96, height: 70)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                if model.isKeeping(candidate.url) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .padding(4)
                                } else if model.isRejecting(candidate.url) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .padding(4)
                                }
                            }
                            .overlay {
                                CullFrameSelectionBorder(
                                    isHighlighted: model.isFocusedFrame(candidate.url),
                                    cornerRadius: 6
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate.filename)
                        .id(candidate.url)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
            }
            .task(id: model.selectedFrameURL) {
                guard let selectedFrameURL = model.selectedFrameURL else { return }
                await Task.yield()
                guard !Task.isCancelled, model.selectedFrameURL == selectedFrameURL else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(selectedFrameURL, anchor: .center)
                }
            }
        }
        .frame(height: 76)
    }

    private var moveStatus: some View {
        HStack(spacing: 10) {
            if model.isMoving {
                Label("Moving cull frame…", systemImage: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let summary = model.lastMoveSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Keep or Reject to review the next frame.", systemImage: "hand.point.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.canUndoLastMove {
                Button("Undo") { model.undoLastMove() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var captureLabel: String {
        frame.captureDate?.formatted(date: .omitted, time: .standard) ?? "No capture time"
    }

    private func resizePreview(by translation: CGFloat) {
        if previewHeightAtDragStart == nil {
            previewHeightAtDragStart = previewHeight
        }
        let startingHeight = previewHeightAtDragStart ?? previewHeight
        previewHeight = min(
            max(startingHeight + Double(translation), minimumPreviewHeight),
            maximumPreviewHeight
        )
    }

    private var resolvedPreviewHeight: CGFloat {
        CGFloat(
            min(
                max(previewHeight, minimumPreviewHeight),
                maximumPreviewHeight
            )
        )
    }
}

private struct BurstReviewView: View {
    let burst: PhotoBurst
    @Bindable var model: CullViewModel
    let layout: CullReviewLayout
    @AppStorage(PreferenceKeys.cullPreviewHeight) private var previewHeight = 540.0
    @AppStorage(PreferenceKeys.cullShowsAFTarget) private var showsCameraAFTarget = true
    @State private var previewHeightAtDragStart: Double?
    @State private var viewport = CullPreviewViewport()

    private let defaultPreviewHeight = 540.0
    private let minimumPreviewHeight = 360.0
    private let maximumPreviewHeight = 1_200.0

    private var selectedFrame: CullPhoto? {
        burst.frames.first { $0.url == model.selectedFrameURL } ?? burst.frames.first
    }

    private var selectedFramePosition: Int {
        guard let selectedFrame,
              let index = burst.frames.firstIndex(of: selectedFrame) else { return 1 }
        return index + 1
    }

    var body: some View {
        Group {
            switch layout {
            case .browse:
                ScrollView {
                    browseContent
                }
            case .review:
                compactReviewContent
            case .focus:
                focusReviewContent
            }
        }
        .onChange(of: burst.id) {
            viewport = CullPreviewViewport()
        }
        .task(id: burst.id) {
            model.loadCameraAFTargets(in: burst)
            await Task.detached(priority: .utility) {
                CullPreviewCache.shared.prefetch(burst.frames.map(\.url))
            }.value
        }
    }

    private var browseContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            standardHeader

            if let selectedFrame {
                HStack(alignment: .top, spacing: 18) {
                    mainPreview(for: selectedFrame, height: resolvedPreviewHeight)
                    frameInspector(for: selectedFrame, height: resolvedPreviewHeight)
                }
            }

            CullPreviewHeightResizeHandle(
                onChanged: resizePreview,
                onEnded: { previewHeightAtDragStart = nil },
                onReset: {
                    previewHeight = defaultPreviewHeight
                    previewHeightAtDragStart = nil
                }
            )

            HStack {
                Text("Frames")
                    .font(.headline)
                Spacer()
                if burst.frames.count > 1, selectedFrame != nil {
                    Button("Keep selected, reject \(burst.frames.count - 1)") {
                        model.keepSelectedAndRejectRest(in: burst)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Keep all") { model.markAllKeeping(in: burst) }
                Button("Reject all") { model.markAllRejecting(in: burst) }
                Button("Clear marks") { model.clearDispositions(in: burst) }
            }
            .disabled(model.isMoving)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(burst.frames) { frame in
                        Button {
                            model.selectFrame(
                                frame.url,
                                extendingQuickExportSelection: NSEvent.modifierFlags.contains(.command),
                                selectingQuickExportRange: NSEvent.modifierFlags.contains(.shift)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                CullPreviewView(url: frame.url, size: .thumbnail)
                                    .frame(width: 142, height: 106)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        CullFrameSelectionBorder(
                                            isHighlighted: model.isFocusedFrame(frame.url),
                                            cornerRadius: 6
                                        )
                                    }
                                Text(frame.filename)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    if model.isKeeping(frame.url) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else if model.isRejecting(frame.url) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    Text(captureLabel(frame))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(height: 14)
                            }
                            .frame(width: 142, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(frame.filename)
                        .id(frame.url)
                    }
                }
                .padding(.bottom, 4)
                }
                .task(id: model.selectedFrameURL) {
                    await scrollSelectedFrame(model.selectedFrameURL, using: proxy)
                }
            }

            if let inspectionSource = model.inspectionSource {
                CullInspectionCropSection(
                    burst: burst,
                    inspectionSource: inspectionSource,
                    model: model
                )
            } else if model.isPickingInspectionPoint {
                CullInspectionPickingState(
                    cancel: model.cancelPickingInspectionPoint
                )
            } else {
                CullInspectionEmptyState(
                    hasCameraAFTarget: selectedFrame.flatMap { model.cameraAFTarget(for: $0.url) } != nil,
                    useCameraAFTarget: model.useCameraAFTarget,
                    pickDetail: model.beginPickingInspectionPoint
                )
            }

            HStack(spacing: 10) {
                if model.isMoving {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Moving cull frame\(model.movingFrameCount == 1 ? "" : "s")…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let summary = model.lastMoveSummary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Keep and Reject move files immediately; unmarked frames stay in this folder.",
                        systemImage: "hand.point.up.left"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if model.canUndoLastMove {
                    Button("Undo") { model.undoLastMove() }
                        .buttonStyle(.bordered)
                        .disabled(model.isMoving)
                }
            }
        }
        .padding(24)
    }

    private var standardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(burst.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(burst.frames.count) related frames · frame \(selectedFramePosition) of \(burst.frames.count)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func mainPreview(for frame: CullPhoto, height: CGFloat? = nil) -> some View {
        if let height {
            CullInspectionPreviewView(
                url: frame.url,
                inspectionPoint: model.inspectionPoint,
                cameraAFTarget: showsCameraAFTarget ? model.cameraAFTarget(for: frame.url) : nil,
                isPickingInspectionPoint: model.isPickingInspectionPoint,
                onInspectionPointSelected: model.setInspectionPoint,
                viewport: $viewport
            )
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        } else {
            CullInspectionPreviewView(
                url: frame.url,
                inspectionPoint: model.inspectionPoint,
                cameraAFTarget: showsCameraAFTarget ? model.cameraAFTarget(for: frame.url) : nil,
                isPickingInspectionPoint: model.isPickingInspectionPoint,
                onInspectionPointSelected: model.setInspectionPoint,
                viewport: $viewport
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func frameInspector(for frame: CullPhoto, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorHeader(for: frame)

            Divider()
            decisionControls(for: frame)

            Divider()
            focusSection(for: frame)

            Spacer(minLength: 8)
            safetyHint
            CullLibraryStatisticsInspector(library: model.library)
        }
        .frame(width: 230, alignment: .leading)
        .frame(minHeight: height, maxHeight: height, alignment: .topLeading)
    }

    private func inspectorHeader(for frame: CullPhoto) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(frame.filename)
                    .font(.headline)
                    .lineLimit(1)
                Text(captureLabel(frame))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { model.revealSelectedFrame() } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal selected photo in Finder")
        }
    }

    private func decisionControls(for frame: CullPhoto) -> some View {
        HStack(spacing: 7) {
            Button(model.isKeeping(frame.url) ? "Kept" : "Keep") {
                model.toggleKeeping(frame.url)
            }
            .buttonStyle(.borderedProminent)

            Button(model.isRejecting(frame.url) ? "Rejected" : "Reject") {
                model.toggleRejecting(frame.url)
            }
            .buttonStyle(.bordered)

            if model.canUndoLastMove {
                Button { model.undoLastMove() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .help("Undo latest cull move")
                .accessibilityLabel("Undo latest cull move")
            }
        }
        .disabled(model.isMoving)
    }

    private func focusSection(for frame: CullPhoto) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Focus")
                .font(.caption.weight(.semibold))
            focusStatus(for: frame)

            Button(model.isPickingInspectionPoint ? "Cancel picking" : "Pick detail…") {
                if model.isPickingInspectionPoint {
                    model.cancelPickingInspectionPoint()
                } else {
                    model.beginPickingInspectionPoint()
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            if shouldOfferCameraAF(for: frame) {
                Button("Use AF target") { model.useCameraAFTarget() }
                    .buttonStyle(.link)
                    .help("Use camera AF target")
                    .accessibilityLabel("Use camera AF target")
            } else if shouldOfferManualClear(for: frame) {
                Button("Clear focus point") {
                    model.clearInspectionPoint()
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func focusStatus(for frame: CullPhoto) -> some View {
        if model.isPickingInspectionPoint {
            Label("Choose a detail in the preview", systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.inspectionPoint != nil {
            Label("Manual focus point", systemImage: "circle.inset.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        } else if model.isLoadingCameraAFTarget(for: frame.url) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading camera AF data…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let target = model.cameraAFTarget(for: frame.url) {
            HStack(spacing: 6) {
                Label("Camera AF target", systemImage: "viewfinder")
                Spacer(minLength: 0)
                Label(target.state.displayName, systemImage: "circle.fill")
                    .foregroundStyle(target.state == .focused ? .green : .secondary)
            }
            .font(.caption.weight(.semibold))
        } else if model.hasLoadedCameraAFTarget(for: frame.url) {
            Text("No active camera AF target recorded")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shouldOfferCameraAF(for frame: CullPhoto) -> Bool {
        !model.isPickingInspectionPoint &&
            !model.isUsingCameraAFTarget &&
            model.cameraAFTarget(for: frame.url) != nil
    }

    private func shouldOfferManualClear(for frame: CullPhoto) -> Bool {
        !model.isPickingInspectionPoint &&
            model.inspectionPoint != nil &&
            model.cameraAFTarget(for: frame.url) == nil
    }

    private var safetyHint: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Keep and Reject move the raw and its sidecars immediately. Undo returns the latest move; nothing is deleted.")
            .accessibilityLabel("Keep and Reject move the raw and its sidecars immediately. Undo returns the latest move; nothing is deleted.")
    }

    private var compactReviewContent: some View {
        VStack(spacing: 10) {
            compactHeader
            if let selectedFrame {
                mainPreview(for: selectedFrame)
                    .padding(.horizontal, 14)
            }
            compactFilmstrip
        }
        .padding(.vertical, 12)
    }

    private var focusReviewContent: some View {
        ZStack(alignment: .bottom) {
            if let selectedFrame {
                mainPreview(for: selectedFrame)
                    .clipShape(Rectangle())
            } else {
                Color.black
            }

            VStack(spacing: 0) {
                focusHeader
                Spacer()
                compactFilmstrip
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.68))
            }
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(burst.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Frame \(selectedFramePosition) of \(burst.frames.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            compactDecisionControls
        }
        .padding(.horizontal, 16)
    }

    private var focusHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(burst.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Frame \(selectedFramePosition) of \(burst.frames.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            compactDecisionControls
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.76), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var compactDecisionControls: some View {
        HStack(spacing: 7) {
            if let selectedFrame {
                Button(model.isKeeping(selectedFrame.url) ? "Kept" : "Keep") {
                    model.toggleKeeping(selectedFrame.url)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isMoving)

                Button(model.isRejecting(selectedFrame.url) ? "Rejected" : "Reject") {
                    model.toggleRejecting(selectedFrame.url)
                }
                .buttonStyle(.bordered)
                .disabled(model.isMoving)
            }

            Menu("More") {
                if burst.frames.count > 1, selectedFrame != nil {
                    Button("Keep selected, reject \(burst.frames.count - 1)") {
                        model.keepSelectedAndRejectRest(in: burst)
                    }
                }
                Button("Keep all") { model.markAllKeeping(in: burst) }
                Button("Reject all") { model.markAllRejecting(in: burst) }
                Button("Clear marks") { model.clearDispositions(in: burst) }
                Divider()
                Button("Reveal Selected") { model.revealSelectedFrame() }
                Button(model.isPickingInspectionPoint ? "Cancel picking" : "Pick detail…") {
                    if model.isPickingInspectionPoint {
                        model.cancelPickingInspectionPoint()
                    } else {
                        model.beginPickingInspectionPoint()
                    }
                }
                if model.inspectionSource != nil {
                    Button("Clear inspection target") {
                        model.clearInspectionPoint()
                    }
                }
            }
            .disabled(model.isMoving)
        }
        .controlSize(.small)
    }

    private var compactFilmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(burst.frames) { frame in
                    Button {
                        model.selectFrame(
                            frame.url,
                            extendingQuickExportSelection: NSEvent.modifierFlags.contains(.command),
                            selectingQuickExportRange: NSEvent.modifierFlags.contains(.shift)
                        )
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            CullPreviewView(url: frame.url, size: .thumbnail)
                                .frame(width: 96, height: 70)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            if model.isKeeping(frame.url) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .padding(4)
                            } else if model.isRejecting(frame.url) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .padding(4)
                            }
                        }
                        .overlay {
                            CullFrameSelectionBorder(
                                isHighlighted: model.isFocusedFrame(frame.url),
                                cornerRadius: 6
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(frame.filename)
                    .id(frame.url)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            }
            .task(id: model.selectedFrameURL) {
                await scrollSelectedFrame(model.selectedFrameURL, using: proxy)
            }
        }
        .frame(height: 76)
    }

    /// Wait one SwiftUI update so the selected card has entered the horizontal
    /// layout, then center it. The task is keyed to the selection, so fast
    /// arrow navigation cancels an obsolete request instead of scrolling back.
    private func scrollSelectedFrame(_ frameURL: URL?, using proxy: ScrollViewProxy) async {
        guard let frameURL else { return }
        await Task.yield()
        guard !Task.isCancelled, model.selectedFrameURL == frameURL else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            proxy.scrollTo(frameURL, anchor: .center)
        }
    }

    private func resizePreview(by translation: CGFloat) {
        if previewHeightAtDragStart == nil {
            previewHeightAtDragStart = previewHeight
        }
        let startingHeight = previewHeightAtDragStart ?? previewHeight
        previewHeight = min(
            max(startingHeight + Double(translation), minimumPreviewHeight),
            maximumPreviewHeight
        )
    }

    private var resolvedPreviewHeight: CGFloat {
        CGFloat(
            min(
                max(previewHeight, minimumPreviewHeight),
                maximumPreviewHeight
            )
        )
    }

    private func captureLabel(_ frame: CullPhoto) -> String {
        guard let date = frame.captureDate else { return "No capture time" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func inspectionHint(for model: CullViewModel) -> String {
        if model.isPickingInspectionPoint {
            return "Click the subject detail you want to compare."
        }
        if model.isUsingCameraAFTarget {
            return "Uses each frame’s camera-recorded AF target. It may be a subject area, not a precise eye."
        }
        return "Choose a detail to compare the same image area across every frame."
    }
}

private struct CullPreviewHeightResizeHandle: View {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.28) : Color.clear)
            .frame(height: 10)
            .overlay {
                Capsule()
                    .fill(isHovering ? Color.accentColor : Color.secondary.opacity(0.52))
                    .frame(width: 38, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChanged(value.translation.height)
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
            .onTapGesture(count: 2) {
                onReset()
            }
            .accessibilityLabel("Preview height")
            .accessibilityHint("Drag vertically to resize the photo preview. Double-click to reset.")
            .help("Drag to resize the preview. Double-click to reset.")
    }
}

enum CullPreviewSize {
    case thumbnail
    case large

    var maxPixelSize: Int {
        switch self {
        case .thumbnail: return 640
        case .large: return 1_600
        }
    }
}

struct CullPreviewView: View {
    let url: URL
    let size: CullPreviewSize
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if didFail {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            image = nil
            didFail = false
            let loaded = await Task.detached(priority: .userInitiated) {
                CullPreviewCache.shared.preview(for: url, maxPixelSize: size.maxPixelSize)
            }.value
            image = loaded
            didFail = loaded == nil
        }
    }
}

/// A normal cull preview with an optional, photographer-chosen inspection
/// point. The point is stored as a fraction of the actual image, not the view,
/// so it remains useful when comparing a differently sized preview.
private struct CullInspectionPreviewView: View {
    let url: URL
    let inspectionPoint: CullInspectionPoint?
    let cameraAFTarget: CameraAFTarget?
    let isPickingInspectionPoint: Bool
    let onInspectionPointSelected: (CullInspectionPoint) -> Void
    @Binding var viewport: CullPreviewViewport

    @State private var image: NSImage?
    @State private var didFail = false
    @State private var fullPreview: NSImage?
    @State private var fullPreviewState: FullPreviewState = .idle
    @State private var fullPreviewRetryCount = 0
    @State private var inspectionHoverLocation: CGPoint?
    @GestureState private var gestureMagnification: CGFloat = 1
    @GestureState private var gestureTranslation: CGSize = .zero

    private var effectiveZoom: CGFloat {
        min(
            max(viewport.zoom * gestureMagnification, CullPreviewViewport.minimumZoom),
            CullPreviewViewport.maximumZoom
        )
    }

    private var fullPreviewRequestID: String {
        guard effectiveZoom > 1.02,
              image != nil,
              fullPreview == nil,
              fullPreviewState != .failed else {
            return ""
        }
        return "\(url.path)#full-preview#\(fullPreviewRetryCount)"
    }

    var body: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    zoomablePreview(in: geometry, image: fullPreview ?? image)
                }
            } else if didFail {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            image = nil
            didFail = false
            fullPreview = nil
            fullPreviewState = .idle
            fullPreviewRetryCount = 0
            let loaded = await Task.detached(priority: .userInitiated) {
                CullPreviewCache.shared.preview(for: url, maxPixelSize: CullPreviewSize.large.maxPixelSize)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
            didFail = loaded == nil
        }
        .task(id: fullPreviewRequestID) {
            guard !fullPreviewRequestID.isEmpty,
                  image != nil,
                  fullPreview == nil,
                  fullPreviewState != .failed else { return }
            let requestID = fullPreviewRequestID
            fullPreviewState = .loading
            let loaded = await CullPreviewCache.shared.fullPreview(for: url)
            guard !Task.isCancelled else { return }
            guard fullPreviewRequestID == requestID else { return }
            if let loaded {
                fullPreview = loaded
                fullPreviewState = .idle
            } else {
                fullPreviewState = .failed
            }
        }
        .onChange(of: isPickingInspectionPoint) { _, isPicking in
            if isPicking {
                viewport.zoom = CullPreviewViewport.minimumZoom
            } else {
                inspectionHoverLocation = nil
            }
        }
    }

    @ViewBuilder
    private func zoomablePreview(in geometry: GeometryProxy, image: NSImage) -> some View {
        let baseRect = CullInspectionGeometry.fittedImageRect(
            imageSize: image.size,
            in: geometry.size
        )
        let zoomedSize = CGSize(
            width: baseRect.width * effectiveZoom,
            height: baseRect.height * effectiveZoom
        )
        let displayedCenter = centeredImagePoint(
            from: viewport.center,
            translation: gestureTranslation,
            imageSize: zoomedSize,
            containerSize: geometry.size
        )
        let imageRect = CGRect(
            x: geometry.size.width / 2 - zoomedSize.width * CGFloat(displayedCenter.x),
            y: geometry.size.height / 2 - zoomedSize.height * CGFloat(displayedCenter.y),
            width: zoomedSize.width,
            height: zoomedSize.height
        )

        ZStack(alignment: .topTrailing) {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                if let inspectionPoint {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor.opacity(0.18)))
                        .shadow(color: Color.accentColor.opacity(0.5), radius: 4)
                        .position(
                            x: imageRect.minX + imageRect.width * CGFloat(inspectionPoint.x),
                            y: imageRect.minY + imageRect.height * CGFloat(inspectionPoint.y)
                        )
                        .allowsHitTesting(false)
                }

                if let cameraAFTarget {
                    let targetRect = cameraAFTarget.normalizedRect
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.yellow, lineWidth: 2)
                        .shadow(color: .black.opacity(0.75), radius: 1)
                        .frame(
                            width: max(2, imageRect.width * targetRect.width),
                            height: max(2, imageRect.height * targetRect.height)
                        )
                        .position(
                            x: imageRect.minX + imageRect.width * targetRect.midX,
                            y: imageRect.minY + imageRect.height * targetRect.midY
                        )
                        .accessibilityLabel("Camera AF target")
                        .allowsHitTesting(false)
                }

                if isPickingInspectionPoint {
                    if let inspectionHoverLocation {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.18))
                                .frame(width: 34, height: 34)
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .frame(width: 34, height: 34)
                            Image(systemName: "magnifyingglass")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 5)
                        .position(inspectionHoverLocation)
                        .allowsHitTesting(false)
                    }

                    Label("Choose a detail to inspect", systemImage: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
            .onContinuousHover { phase in
                guard isPickingInspectionPoint else {
                    inspectionHoverLocation = nil
                    return
                }
                switch phase {
                case let .active(location):
                    inspectionHoverLocation = imageRect.contains(location) ? location : nil
                case .ended:
                    inspectionHoverLocation = nil
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard isPickingInspectionPoint,
                              imageRect.contains(value.location) else {
                            return
                        }
                        onInspectionPointSelected(
                            CullInspectionPoint(
                                x: Double((value.location.x - imageRect.minX) / imageRect.width),
                                y: Double((value.location.y - imageRect.minY) / imageRect.height)
                            )
                        )
                    }
            )
            .simultaneousGesture(panGesture(in: geometry.size, imageSize: zoomedSize))
            .simultaneousGesture(magnificationGesture(baseRect: baseRect, containerSize: geometry.size))
            .onTapGesture(count: 2) {
                guard !isPickingInspectionPoint else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    viewport.zoom = CullPreviewViewport.zoomAfterDoubleClick(from: effectiveZoom)
                    viewport.center = clampedCenter(
                        viewport.center,
                        imageSize: CGSize(width: baseRect.width * viewport.zoom, height: baseRect.height * viewport.zoom),
                        containerSize: geometry.size
                    )
                }
            }

            if effectiveZoom > 1.02, fullPreview == nil {
                switch fullPreviewState {
                case .idle, .loading:
                    Label("Loading full JPEG preview…", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .padding(8)
                        .background(.black.opacity(0.72), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                        .allowsHitTesting(false)
                case .failed:
                    Button {
                        retryFullPreview()
                    } label: {
                        Label("Full JPEG preview unavailable — Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .padding(8)
                            .background(.black.opacity(0.72), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
            }
        }
    }

    private func retryFullPreview() {
        fullPreviewState = .idle
        fullPreviewRetryCount += 1
    }

    private func panGesture(in containerSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($gestureTranslation) { value, state, _ in
                guard !isPickingInspectionPoint else { return }
                state = value.translation
            }
            .onEnded { value in
                guard !isPickingInspectionPoint else { return }
                viewport.center = centeredImagePoint(
                    from: viewport.center,
                    translation: value.translation,
                    imageSize: imageSize,
                    containerSize: containerSize
                )
            }
    }

    private func magnificationGesture(
        baseRect: CGRect,
        containerSize: CGSize
    ) -> some Gesture {
        MagnifyGesture()
            .updating($gestureMagnification) { value, state, _ in
                guard !isPickingInspectionPoint else { return }
                state = value.magnification
            }
            .onEnded { value in
                guard !isPickingInspectionPoint else { return }
                viewport.zoom = min(
                    max(viewport.zoom * value.magnification, CullPreviewViewport.minimumZoom),
                    CullPreviewViewport.maximumZoom
                )
                viewport.center = clampedCenter(
                    viewport.center,
                    imageSize: CGSize(width: baseRect.width * viewport.zoom, height: baseRect.height * viewport.zoom),
                    containerSize: containerSize
                )
            }
    }

    private func centeredImagePoint(
        from center: CullInspectionPoint,
        translation: CGSize,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CullInspectionPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return center }
        return clampedCenter(
            CullInspectionPoint(
                x: center.x - Double(translation.width / imageSize.width),
                y: center.y - Double(translation.height / imageSize.height)
            ),
            imageSize: imageSize,
            containerSize: containerSize
        )
    }

    private func clampedCenter(
        _ center: CullInspectionPoint,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CullInspectionPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return center }
        let visibleWidth = min(1, containerSize.width / imageSize.width)
        let visibleHeight = min(1, containerSize.height / imageSize.height)
        let minimumX = visibleWidth / 2
        let maximumX = 1 - minimumX
        let minimumY = visibleHeight / 2
        let maximumY = 1 - minimumY
        return CullInspectionPoint(
            x: Double(min(max(CGFloat(center.x), minimumX), maximumX)),
            y: Double(min(max(CGFloat(center.y), minimumY), maximumY))
        )
    }
}

private enum FullPreviewState: Equatable {
    case idle
    case loading
    case failed
}

/// The comparison strip begins with a direct choice of its source, so the
/// photographer can see both the immediate action and the resulting view.
private struct CullInspectionEmptyState: View {
    let hasCameraAFTarget: Bool
    let useCameraAFTarget: () -> Void
    let pickDetail: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("Compare a detail across this burst")
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if hasCameraAFTarget {
                    Button("Use camera focus area", action: useCameraAFTarget)
                        .buttonStyle(.borderedProminent)
                }

                if hasCameraAFTarget {
                    Button("Pick a detail", action: pickDetail)
                        .buttonStyle(.bordered)
                } else {
                    Button("Pick a detail", action: pickDetail)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var description: String {
        hasCameraAFTarget
            ? "Use the camera’s focus area, or click a detail in the photo. Fotocopy will show one close-up from every frame."
            : "Click a detail in the photo. Fotocopy will show one close-up from every frame."
    }
}

/// During manual selection, this replaces the zero state while the preview
/// itself presents the click target and captures the chosen image position.
private struct CullInspectionPickingState: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cursorarrow.click")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a detail in the photo")
                    .font(.headline)
                Text("Fotocopy will show this area from every frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CullInspectionCropSection: View {
    let burst: PhotoBurst
    let inspectionSource: CullInspectionSource
    @Bindable var model: CullViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detail comparison")
                        .font(.headline)
                    Text(cropDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(burst.frames) { frame in
                        Button {
                            model.selectFrame(
                                frame.url,
                                extendingQuickExportSelection: NSEvent.modifierFlags.contains(.command),
                                selectingQuickExportRange: NSEvent.modifierFlags.contains(.shift)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                inspectionCrop(for: frame)
                                Text(frame.filename)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                if model.isKeeping(frame.url) {
                                    Label("Marked to keep", systemImage: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                } else {
                                    Text(captureLabel(frame))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 156, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Inspection crop for \(frame.filename)")
                        .id(frame.url)
                    }
                }
                .padding(.bottom, 4)
                }
                .task(id: model.selectedFrameURL) {
                    await scrollSelectedFrame(model.selectedFrameURL, using: proxy)
                }
            }

            Label(
                inspectionSource == .cameraAF
                    ? "Uses the recorded AF target for each individual frame. A frame without one is left blank rather than guessed."
                    : "This follows image position, not the moving subject. Re-pick the point when the subject has moved too far.",
                systemImage: inspectionSource == .cameraAF ? "viewfinder" : "hand.point.up.left"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func captureLabel(_ frame: CullPhoto) -> String {
        guard let date = frame.captureDate else { return "No capture time" }
        return date.formatted(date: .omitted, time: .standard)
    }

    /// Match the Frames filmstrip whenever keyboard navigation changes the
    /// selected frame. Yielding lets the lazy crop card join the scroll view
    /// before scrolling to it.
    private func scrollSelectedFrame(_ frameURL: URL?, using proxy: ScrollViewProxy) async {
        guard let frameURL else { return }
        await Task.yield()
        guard !Task.isCancelled, model.selectedFrameURL == frameURL else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            proxy.scrollTo(frameURL, anchor: .center)
        }
    }

    private var cropDescription: String {
        switch inspectionSource {
        case .manual:
            return "Selected image area across every frame."
        case .cameraAF:
            return "Camera focus area from every frame."
        }
    }

    @ViewBuilder
    private func inspectionCrop(for frame: CullPhoto) -> some View {
        Group {
            if let point = model.inspectionPoint(for: frame) {
                CullInspectionCropView(url: frame.url, inspectionPoint: point)
            } else {
                ContentUnavailableView(
                    "No AF target",
                    systemImage: "viewfinder",
                    description: Text("Not recorded")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 156, height: 156)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            CullFrameSelectionBorder(
                isHighlighted: model.isFocusedFrame(frame.url),
                cornerRadius: 7
            )
        }
    }
}

private struct CullInspectionCropView: View {
    let url: URL
    let inspectionPoint: CullInspectionPoint
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: "\(url.path)#\(inspectionPoint.cacheKey)") {
            image = nil
            didFail = false
            let loaded = await Task.detached(priority: .userInitiated) {
                CullPreviewCache.shared.focusCrop(for: url, around: inspectionPoint)
            }.value
            image = loaded
            didFail = loaded == nil
        }
    }
}

/// SwiftUI's focus can legitimately be in the burst list or a button while a
/// photographer is reviewing. A local monitor keeps plain arrow keys dedicated
/// to culling without stealing shortcuts or text editing.
private struct CullNavigationKeyHandler: NSViewRepresentable {
    let moveFrame: (Int) -> Void
    let moveBurst: (Int) -> Void
    let keepCurrentFrame: () -> Void
    let keepCurrentAndRejectRest: () -> Void
    let rejectCurrentFrame: () -> Void
    let rejectBurst: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            moveFrame: moveFrame,
            moveBurst: moveBurst,
            keepCurrentFrame: keepCurrentFrame,
            keepCurrentAndRejectRest: keepCurrentAndRejectRest,
            rejectCurrentFrame: rejectCurrentFrame,
            rejectBurst: rejectBurst
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.moveFrame = moveFrame
        context.coordinator.moveBurst = moveBurst
        context.coordinator.keepCurrentFrame = keepCurrentFrame
        context.coordinator.keepCurrentAndRejectRest = keepCurrentAndRejectRest
        context.coordinator.rejectCurrentFrame = rejectCurrentFrame
        context.coordinator.rejectBurst = rejectBurst
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var moveFrame: (Int) -> Void
        var moveBurst: (Int) -> Void
        var keepCurrentFrame: () -> Void
        var keepCurrentAndRejectRest: () -> Void
        var rejectCurrentFrame: () -> Void
        var rejectBurst: () -> Void
        private var monitor: Any?

        init(
            moveFrame: @escaping (Int) -> Void,
            moveBurst: @escaping (Int) -> Void,
            keepCurrentFrame: @escaping () -> Void,
            keepCurrentAndRejectRest: @escaping () -> Void,
            rejectCurrentFrame: @escaping () -> Void,
            rejectBurst: @escaping () -> Void
        ) {
            self.moveFrame = moveFrame
            self.moveBurst = moveBurst
            self.keepCurrentFrame = keepCurrentFrame
            self.keepCurrentAndRejectRest = keepCurrentAndRejectRest
            self.rejectCurrentFrame = rejectCurrentFrame
            self.rejectBurst = rejectBurst
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      NSApp.modalWindow == nil,
                      event.window?.attachedSheet == nil,
                      !Self.isEditingText(in: event.window),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let action = CullKeyboardShortcuts.action(
                          keyCode: event.keyCode,
                          charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                          shiftPressed: event.modifierFlags.contains(.shift)
                      ) else {
                    return event
                }

                if event.isARepeat, action.isDecision {
                    return nil
                }

                switch action {
                case .moveFrame(-1):
                    self.moveFrame(-1)
                    return nil
                case .moveFrame(1):
                    self.moveFrame(1)
                    return nil
                case .moveBurst(-1):
                    self.moveBurst(-1)
                    return nil
                case .moveBurst(1):
                    self.moveBurst(1)
                    return nil
                case .keepCurrentFrame:
                    self.keepCurrentFrame()
                    return nil
                case .keepCurrentAndRejectRest:
                    self.keepCurrentAndRejectRest()
                    return nil
                case .rejectCurrentFrame:
                    self.rejectCurrentFrame()
                    return nil
                case .rejectBurst:
                    self.rejectBurst()
                    return nil
                case .moveFrame, .moveBurst:
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func isEditingText(in window: NSWindow?) -> Bool {
            window?.firstResponder is NSTextView
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct CullFrameDispositionState: Sendable {
    let frameURL: URL
    let disposition: CullDisposition?
}

/// Blue identifies the frame currently shown in the review preview. Quick
/// Export has a separate, non-visual multi-selection state.
private struct CullFrameSelectionBorder: View {
    let isHighlighted: Bool
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(isHighlighted ? Color.accentColor : Color.clear, lineWidth: 3)
    }
}

private struct CullUndoOperation: Sendable {
    let restoreStates: [CullFrameDispositionState]
    let movedFrameCount: Int
}

@Observable
@MainActor
final class CullViewModel {
    var destination: CullDestination = .review(nil)
    var folderURL: URL?
    var scanResult: CullFolderScan?
    var isScanning = false
    var progressCompleted = 0
    var progressTotal = 0
    var currentFilename = ""
    var errorMessage: String?
    var showError = false
    var moveErrorMessage: String?
    var showMoveError = false
    var isMoving = false
    var movingFrameCount = 0
    var lastMoveSummary: String?
    var quickExportSelection = CullQuickExportSelection()
    var isQuickExporting = false
    var quickExportAlertTitle = "Quick Export"
    var quickExportAlertMessage = ""
    var showQuickExportAlert = false
    private(set) var previousCullFolderURL: URL?
    private(set) var nextCullFolderURL: URL?
    var selectedFrameURL: URL?
    /// Singles open as a visual timeline. Keep/Reject moves selection to the
    /// next undecided photo but leaves its decided thumbnail visible.
    var singleFrameFilter: SingleFrameReviewFilter = .all
    var inspectionSource: CullInspectionSource?
    var isPickingInspectionPoint = false
    let library = CullLibraryViewModel()
    private(set) var dispositions: [URL: CullDisposition] = [:]
    private(set) var cameraAFTargets: [URL: CameraAFTarget] = [:]
    private(set) var loadedCameraAFTargetURLs: Set<URL> = []
    private(set) var loadingCameraAFTargetURLs: Set<URL> = []

    private var scanTask: Task<Void, Never>?
    private var preferredReviewGroupIDAfterScan: CullReviewGroupID?
    private var selectsLastReviewGroupAfterScan = false
    private var selectsLastFrameAfterScan = false
    private var folderNavigationTask: Task<Void, Never>?
    private var lastUndoOperation: CullUndoOperation?

    init() {
        if let path = UserDefaults.standard.string(forKey: PreferenceKeys.lastCullFolder) {
            folderURL = URL(fileURLWithPath: path)
        }
    }

    var recentImportedFolders: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: PreferenceKeys.recentCullFolders) ?? []
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var selectedReviewGroupID: CullReviewGroupID? {
        guard case let .review(groupID) = destination else { return nil }
        return groupID
    }

    var selectedReviewGroup: CullReviewGroup? {
        guard let selectedReviewGroupID else { return nil }
        return scanResult?.reviewGroups.first { $0.id == selectedReviewGroupID }
    }

    var isReviewingSingles: Bool {
        selectedReviewGroupID == .singleFrames
    }

    var selectedBurst: PhotoBurst? {
        guard case let .burst(burstID) = selectedReviewGroupID else { return nil }
        return scanResult?.bursts.first { $0.id == burstID }
    }

    var filteredSingleFrames: [CullPhoto] {
        guard let frames = scanResult?.singleFrames else { return [] }
        return frames.filter { singleFrameFilter.includes(dispositions[$0.url]) }
    }

    private func visibleFrames(in group: CullReviewGroup) -> [CullPhoto] {
        group.id == .singleFrames ? filteredSingleFrames : group.frames
    }

    var selectedSingleFrame: CullPhoto? {
        guard isReviewingSingles,
              let selectedFrameURL else { return nil }
        return filteredSingleFrames.first { $0.url == selectedFrameURL }
    }

    var undecidedSingleFrameCount: Int {
        scanResult?.singleFrames.count { dispositions[$0.url] == nil } ?? 0
    }

    var canUndoLastMove: Bool { lastUndoOperation != nil && !isMoving }

    var selectedQuickExportURLs: [URL] {
        let frames = (scanResult?.bursts.flatMap(\.frames) ?? []) + (scanResult?.singleFrames ?? [])
        return quickExportSelection.selectedURLs(from: frames, fallback: selectedFrameURL)
    }

    var canQuickExport: Bool {
        !selectedQuickExportURLs.isEmpty && !isScanning && !isMoving && !isQuickExporting
    }

    var canNavigatePreviousCullFolder: Bool {
        previousCullFolderURL != nil && !isScanning && !isMoving
    }

    var canNavigateNextCullFolder: Bool {
        nextCullFolderURL != nil && !isScanning && !isMoving
    }

    /// A manual choice takes precedence. Camera AF mode resolves the target
    /// separately for every frame, so the crop can follow a moving subject.
    var inspectionPoint: CullInspectionPoint? {
        inspectionSource?.manualPoint
    }

    var isUsingCameraAFTarget: Bool {
        inspectionSource == .cameraAF
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Review Folder"
        panel.message = "Choose one Fotocopy destination folder containing CR3 photos. Fotocopy moves only the Keep or Reject choices you make; nothing is deleted."
        if let folderURL {
            panel.directoryURL = folderURL
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestUse(folder: url)
    }

    func requestUse(folder: URL) {
        use(folder: folder)
    }

    func moveCullFolder(by offset: Int) {
        moveCullFolder(by: offset, enteringAtReviewBoundary: false)
    }

    private func moveCullFolder(by offset: Int, enteringAtReviewBoundary: Bool) {
        guard !isScanning, !isMoving else { return }

        switch offset {
        case ..<0:
            guard let previousCullFolderURL else { return }
            if enteringAtReviewBoundary {
                use(
                    folder: previousCullFolderURL,
                    selectingLastReviewGroup: true,
                    selectingLastFrame: true
                )
            } else {
                use(folder: previousCullFolderURL, preferring: selectedReviewGroupID)
            }
        case 1...:
            guard let nextCullFolderURL else { return }
            if enteringAtReviewBoundary {
                use(folder: nextCullFolderURL)
            } else {
                use(folder: nextCullFolderURL, preferring: selectedReviewGroupID)
            }
        default:
            return
        }
    }

    func showLibraryDecisions() {
        destination = .libraryDecisions
        library.refreshDecisionsIfNeeded()
    }

    func showBurstCulling() {
        resumeLastScanIfNeeded()
        library.refreshImageStatisticsIfNeeded()
        if selectedReviewGroup == nil,
           let groupID = CullReviewGroupNavigation.initialGroupID(
               in: scanResult?.reviewGroups ?? [],
               preferring: selectedReviewGroupID
           ) {
            selectReviewGroup(withID: groupID)
        }
    }

    func showSingleFrameCulling() {
        if isScanning {
            preferredReviewGroupIDAfterScan = .singleFrames
        } else if scanResult == nil, folderURL != nil, !isMoving {
            startScan(preferring: .singleFrames)
        }
        library.refreshImageStatisticsIfNeeded()
        if scanResult?.reviewGroups.contains(where: { $0.id == .singleFrames }) == true {
            selectReviewGroup(withID: .singleFrames)
        }
    }

    private func use(
        folder: URL,
        preferring reviewGroupID: CullReviewGroupID? = nil,
        selectingLastReviewGroup: Bool = false,
        selectingLastFrame: Bool = false
    ) {
        folderURL = folder
        UserDefaults.standard.set(folder.path, forKey: PreferenceKeys.lastCullFolder)
        startScan(
            preferring: reviewGroupID,
            selectingLastReviewGroup: selectingLastReviewGroup,
            selectingLastFrame: selectingLastFrame
        )
    }

    func scan() {
        library.refreshImageStatistics()
        startScan(preferring: selectedReviewGroupID)
    }

    /// The last reviewed date folder is retained between launches. Start a
    /// fresh, disk-based scan when Cull first appears instead of persisting a
    /// transient burst list.
    func resumeLastScanIfNeeded() {
        guard folderURL != nil, scanResult == nil, !isScanning, !isMoving else { return }
        startScan(preferring: selectedReviewGroupID)
    }

    private func startScan(
        preferring preferredReviewGroupID: CullReviewGroupID? = nil,
        selectingLastReviewGroup: Bool = false,
        selectingLastFrame: Bool = false
    ) {
        guard let folderURL, !isScanning, !isMoving else { return }
        preferredReviewGroupIDAfterScan = preferredReviewGroupID
        selectsLastReviewGroupAfterScan = selectingLastReviewGroup
        selectsLastFrameAfterScan = selectingLastFrame
        refreshCullFolderNavigation(for: folderURL)
        scanTask?.cancel()
        scanResult = nil
        dispositions.removeAll()
        lastUndoOperation = nil
        lastMoveSummary = nil
        destination = .review(nil)
        selectedFrameURL = nil
        quickExportSelection.clear()
        inspectionSource = nil
        isPickingInspectionPoint = false
        cameraAFTargets.removeAll()
        loadedCameraAFTargetURLs.removeAll()
        loadingCameraAFTargetURLs.removeAll()
        isScanning = true
        progressCompleted = 0
        progressTotal = 0
        currentFilename = "Preparing scan…"
        errorMessage = nil

        let model = self
        let workers = CullSettings.scanWorkerCount
        scanTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await BurstGroupingEngine.scan(
                        folder: folderURL,
                        workerCount: workers
                    ) { progress in
                        Task { @MainActor in
                            model.progressCompleted = progress.completed
                            model.progressTotal = progress.total
                            model.currentFilename = progress.filename
                        }
                    }
                }.value

                guard !Task.isCancelled else { return }
                scanResult = result
                dispositions = Self.onDiskDispositions(in: result)
                let groupID = CullReviewGroupNavigation.initialGroupID(
                    in: result.reviewGroups,
                    preferring: preferredReviewGroupIDAfterScan,
                    selectingLastReviewGroup: selectsLastReviewGroupAfterScan
                )
                if let groupID {
                    selectReviewGroup(withID: groupID, selectingLastFrame: selectsLastFrameAfterScan)
                }
                preferredReviewGroupIDAfterScan = nil
                selectsLastReviewGroupAfterScan = false
                selectsLastFrameAfterScan = false
            } catch is CancellationError {
                // A new scan replaced this one.
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

    /// Folder discovery walks only the three date-directory levels and checks
    /// filenames, so it never decodes photos or reads their metadata. Run it
    /// off the main actor to keep the current review responsive on an external
    /// drive.
    private func refreshCullFolderNavigation(for currentFolder: URL) {
        folderNavigationTask?.cancel()
        previousCullFolderURL = nil
        nextCullFolderURL = nil

        let roots = [library.configuredLibraryURL, CullFolderNavigation.libraryRoot(containing: currentFolder)]
            .compactMap { $0 }
            .reduce(into: [URL]()) { roots, root in
                if !roots.contains(where: { $0.standardizedFileURL == root.standardizedFileURL }) {
                    roots.append(root)
                }
            }
        guard !roots.isEmpty else { return }

        let standardizedCurrentFolder = currentFolder.standardizedFileURL
        folderNavigationTask = Task { [weak self] in
            let neighbors = await Task.detached(priority: .utility) { () -> CullFolderNeighbors? in
                for root in roots {
                    if let neighbors = CullFolderNavigation.neighbors(
                        of: standardizedCurrentFolder,
                        in: root
                    ) {
                        return neighbors
                    }
                }
                return nil
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.folderURL?.standardizedFileURL == standardizedCurrentFolder else {
                return
            }
            self.previousCullFolderURL = neighbors?.previous
            self.nextCullFolderURL = neighbors?.next
            self.folderNavigationTask = nil
        }
    }

    func syncSelectedFrame() {
        inspectionSource = nil
        isPickingInspectionPoint = false
        guard let selectedBurst else {
            selectedFrameURL = nil
            return
        }
        if !selectedBurst.frames.contains(where: { $0.url == selectedFrameURL }) {
            selectedFrameURL = selectedBurst.frames.first?.url
        }
    }

    func selectReviewGroup(withID groupID: CullReviewGroupID, selectingLastFrame: Bool = false) {
        guard let group = scanResult?.reviewGroups.first(where: { $0.id == groupID }) else { return }
        destination = .review(group.id)
        selectedFrameURL = selectingLastFrame
            ? visibleFrames(in: group).last?.url
            : visibleFrames(in: group).first?.url
        quickExportSelection.reset(to: selectedFrameURL)
        inspectionSource = nil
        isPickingInspectionPoint = false
        automaticallyUseCameraAFTargetForSelectedFrame()
    }

    func selectFrame(
        _ url: URL,
        extendingQuickExportSelection: Bool = false,
        selectingQuickExportRange: Bool = false
    ) {
        guard let selectedBurst,
              selectedBurst.frames.contains(where: { $0.url == url }) else {
            return
        }
        selectedFrameURL = url
        quickExportSelection.select(
            url,
            in: selectedBurst.frames.map(\.url),
            extendingSelection: extendingQuickExportSelection,
            selectingRange: selectingQuickExportRange
        )
        automaticallyUseCameraAFTargetForSelectedFrame()
    }

    func selectSingleFrame(
        _ url: URL,
        extendingQuickExportSelection: Bool = false,
        selectingQuickExportRange: Bool = false
    ) {
        guard isReviewingSingles,
              filteredSingleFrames.contains(where: { $0.url == url }) else { return }
        selectedFrameURL = url
        quickExportSelection.select(
            url,
            in: filteredSingleFrames.map(\.url),
            extendingSelection: extendingQuickExportSelection,
            selectingRange: selectingQuickExportRange
        )
        inspectionSource = nil
        isPickingInspectionPoint = false
        automaticallyUseCameraAFTargetForSelectedFrame()
    }

    func isQuickExportSelected(_ url: URL) -> Bool {
        selectedQuickExportURLs.contains(url)
    }

    func isFocusedFrame(_ url: URL) -> Bool {
        selectedFrameURL == url
    }

    func quickExportSelectedPhotos(to destinationFolderURL: URL) {
        let sources = selectedQuickExportURLs
        guard !sources.isEmpty, !isQuickExporting else { return }
        isQuickExporting = true

        Task { [sources, destinationFolderURL] in
            defer { isQuickExporting = false }
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try QuickExportEngine.makePlan(
                        sourceURLs: sources,
                        destinationFolderURL: destinationFolderURL
                    )
                }.value
                let result = await Task.detached(priority: .userInitiated) {
                    QuickExportEngine.export(plan)
                }.value
                guard !Task.isCancelled else { return }
                presentQuickExportResult(result, destinationFolderURL: destinationFolderURL)
            } catch {
                guard !Task.isCancelled else { return }
                quickExportAlertTitle = "Could not export JPEGs"
                quickExportAlertMessage = error.localizedDescription
                showQuickExportAlert = true
            }
        }
    }

    private func presentQuickExportResult(
        _ result: QuickExportResult,
        destinationFolderURL: URL
    ) {
        let exportedCount = result.exportedURLs.count
        if result.failures.isEmpty {
            quickExportAlertTitle = "Quick Export Complete"
            quickExportAlertMessage = "Exported \(exportedCount) JPEG \(exportedCount == 1 ? "image" : "images") to \(destinationFolderURL.path)."
        } else {
            quickExportAlertTitle = exportedCount == 0 ? "Could not export JPEGs" : "Quick Export Partially Complete"
            let failedNames = result.failures.map { $0.sourceURL.lastPathComponent }.joined(separator: ", ")
            let successSummary = exportedCount == 0
                ? ""
                : "Exported \(exportedCount) JPEG \(exportedCount == 1 ? "image" : "images"). "
            quickExportAlertMessage = "\(successSummary)Could not export \(failedNames). \(result.failures.first?.message ?? "")"
        }
        showQuickExportAlert = true
    }

    func selectFirstSingleFrameMatchingFilter() {
        guard isReviewingSingles else { return }
        selectedFrameURL = filteredSingleFrames.first?.url
        quickExportSelection.reset(to: selectedFrameURL)
        inspectionSource = nil
        isPickingInspectionPoint = false
    }

    func moveSelectedSingleFrame(by offset: Int) {
        guard !filteredSingleFrames.isEmpty else { return }
        selectedFrameURL = CullFrameNavigation.frameURL(
            in: filteredSingleFrames,
            adjacentTo: selectedFrameURL,
            offset: offset
        )
        quickExportSelection.reset(to: selectedFrameURL)
        automaticallyUseCameraAFTargetForSelectedFrame()
    }

    func moveSelectedReviewFrame(by offset: Int) {
        guard let scanResult, let group = selectedReviewGroup else { return }
        let visibleFrames = self.visibleFrames(in: group)
        if CullReviewGroupNavigation.crossesFolderBoundary(
            in: scanResult.reviewGroups,
            selectedGroupID: group.id,
            visibleFrames: visibleFrames,
            selectedFrameURL: selectedFrameURL,
            offset: offset
        ) {
            moveCullFolder(by: offset, enteringAtReviewBoundary: true)
        } else if isReviewingSingles {
            moveSelectedSingleFrame(by: offset)
        } else if let burst = selectedBurst {
            moveSelectedFrame(in: burst, by: offset)
        }
    }

    func moveSelectedFrame(in burst: PhotoBurst, by offset: Int) {
        selectedFrameURL = CullFrameNavigation.frameURL(
            in: burst.frames,
            adjacentTo: selectedFrameURL,
            offset: offset
        )
        quickExportSelection.reset(to: selectedFrameURL)
        automaticallyUseCameraAFTargetForSelectedFrame()
    }

    func moveSelectedReviewGroup(by offset: Int) {
        guard let scanResult,
              let groupID = CullReviewGroupNavigation.groupID(
                  in: scanResult.reviewGroups,
                  adjacentTo: selectedReviewGroupID,
                  offset: offset
              ) else {
            return
        }
        selectReviewGroup(withID: groupID)
    }

    func beginPickingInspectionPoint() {
        isPickingInspectionPoint = true
    }

    func cancelPickingInspectionPoint() {
        isPickingInspectionPoint = false
    }

    func setInspectionPoint(_ point: CullInspectionPoint) {
        inspectionSource = .manual(point)
        isPickingInspectionPoint = false
    }

    func clearInspectionPoint() {
        inspectionSource = nil
        isPickingInspectionPoint = false
    }

    func useCameraAFTarget() {
        guard let selectedFrameURL, cameraAFTargets[selectedFrameURL] != nil else { return }
        inspectionSource = .cameraAF
        isPickingInspectionPoint = false
    }

    func cameraAFTarget(for url: URL) -> CameraAFTarget? {
        cameraAFTargets[url]
    }

    func hasLoadedCameraAFTarget(for url: URL) -> Bool {
        loadedCameraAFTargetURLs.contains(url)
    }

    func isLoadingCameraAFTarget(for url: URL) -> Bool {
        loadingCameraAFTargetURLs.contains(url)
    }

    func inspectionPoint(for frame: CullPhoto) -> CullInspectionPoint? {
        switch inspectionSource {
        case let .manual(point): return point
        case .cameraAF: return cameraAFTargets[frame.url]?.center
        case nil: return nil
        }
    }

    /// AF metadata is deliberately loaded only for the burst being reviewed,
    /// not for every CR3 during the initial folder scan. That keeps opening a
    /// large external folder responsive while still making the targets ready
    /// before the photographer begins comparing the burst.
    func loadCameraAFTargets(in burst: PhotoBurst) {
        let urls = burst.frames.map(\.url).filter {
            !loadedCameraAFTargetURLs.contains($0) && !loadingCameraAFTargetURLs.contains($0)
        }
        guard !urls.isEmpty else {
            automaticallyUseCameraAFTarget(for: burst)
            return
        }

        loadingCameraAFTargetURLs.formUnion(urls)
        Task { [weak self] in
            let results = await Self.readCameraAFTargets(from: urls)
            guard !Task.isCancelled, let self else { return }

            for (url, target) in results {
                self.loadedCameraAFTargetURLs.insert(url)
                self.loadingCameraAFTargetURLs.remove(url)
                if let target {
                    self.cameraAFTargets[url] = target
                }
            }
            self.automaticallyUseCameraAFTarget(for: burst)
        }
    }

    func loadCameraAFTarget(for frame: CullPhoto) {
        let url = frame.url
        guard !loadedCameraAFTargetURLs.contains(url), !loadingCameraAFTargetURLs.contains(url) else {
            automaticallyUseCameraAFTargetForSelectedFrame()
            return
        }

        loadingCameraAFTargetURLs.insert(url)
        Task { [weak self] in
            let results = await Self.readCameraAFTargets(from: [url])
            guard !Task.isCancelled, let self else { return }
            for (resultURL, target) in results {
                self.loadedCameraAFTargetURLs.insert(resultURL)
                self.loadingCameraAFTargetURLs.remove(resultURL)
                if let target {
                    self.cameraAFTargets[resultURL] = target
                }
            }
            guard self.isReviewingSingles, self.selectedFrameURL == url else { return }
            self.automaticallyUseCameraAFTargetForSelectedFrame()
        }
    }

    private func automaticallyUseCameraAFTarget(for burst: PhotoBurst) {
        guard selectedReviewGroupID == .burst(burst.id) else { return }
        automaticallyUseCameraAFTargetForSelectedFrame()
    }

    /// A burst's AF data arrives asynchronously. Re-evaluate the selected
    /// frame both after that read finishes and after Left/Right changes it, so
    /// a later frame with a target immediately enables its crop comparison.
    private func automaticallyUseCameraAFTargetForSelectedFrame() {
        inspectionSource = CullInspectionSource.automaticallySelected(
            current: inspectionSource,
            selectedFrameHasCameraAFTarget: selectedFrameURL.flatMap { cameraAFTargets[$0] } != nil
        )
    }

    private nonisolated static func readCameraAFTargets(
        from urls: [URL]
    ) async -> [(URL, CameraAFTarget?)] {
        guard !urls.isEmpty else { return [] }
        return await withTaskGroup(of: (URL, CameraAFTarget?).self) { group in
            let workers = min(4, urls.count)
            var nextIndex = 0
            for _ in 0..<workers {
                let url = urls[nextIndex]
                group.addTask { (url, CanonAFMetadataReader.readTarget(from: url)) }
                nextIndex += 1
            }

            var results: [(URL, CameraAFTarget?)] = []
            while let result = await group.next() {
                results.append(result)
                if nextIndex < urls.count {
                    let url = urls[nextIndex]
                    group.addTask { (url, CanonAFMetadataReader.readTarget(from: url)) }
                    nextIndex += 1
                }
            }
            return results
        }
    }

    func isKeeping(_ url: URL) -> Bool {
        dispositions[url] == .select
    }

    func isRejecting(_ url: URL) -> Bool {
        dispositions[url] == .reject
    }

    func toggleKeeping(_ url: URL) {
        let disposition: CullDisposition? = isKeeping(url) ? nil : .select
        moveDisposition(of: url, to: disposition, advanceAfterMove: disposition != nil)
    }

    func toggleRejecting(_ url: URL) {
        let disposition: CullDisposition? = isRejecting(url) ? nil : .reject
        moveDisposition(of: url, to: disposition, advanceAfterMove: disposition != nil)
    }

    /// Keyboard decisions are idempotent: repeated K or X presses never turn
    /// a prior decision back into an unmarked frame.
    func keepSelectedFrame() {
        guard let selectedFrameURL else { return }
        moveDisposition(
            of: selectedFrameURL,
            to: .select,
            advanceAfterMove: !isReviewingSingles,
            advanceAfterMovingSingleFrame: isReviewingSingles ? selectedFrameURL : nil
        )
    }

    func rejectSelectedFrame() {
        guard let selectedFrameURL else { return }
        moveDisposition(
            of: selectedFrameURL,
            to: .reject,
            advanceAfterMove: !isReviewingSingles,
            advanceAfterMovingSingleFrame: isReviewingSingles ? selectedFrameURL : nil
        )
    }

    func clearSelectedFrameDisposition() {
        guard let selectedFrameURL else { return }
        moveDisposition(of: selectedFrameURL, to: nil)
    }

    func keepSelectedAndRejectRest(in burst: PhotoBurst) {
        guard let selectedFrameURL,
              burst.frames.contains(where: { $0.url == selectedFrameURL }) else {
            return
        }
        moveDispositions(
            burst.frames.map {
                CullFrameDispositionState(
                    frameURL: $0.url,
                    disposition: $0.url == selectedFrameURL ? .select : .reject
                )
            },
            advanceAfterMovingBurst: burst.id
        )
    }

    func markAllKeeping(in burst: PhotoBurst) {
        moveDispositions(
            burst.frames.map { CullFrameDispositionState(frameURL: $0.url, disposition: .select) },
            advanceAfterMovingBurst: burst.id
        )
    }

    func markAllRejecting(in burst: PhotoBurst) {
        moveDispositions(
            burst.frames.map { CullFrameDispositionState(frameURL: $0.url, disposition: .reject) },
            advanceAfterMovingBurst: burst.id
        )
    }

    func clearDispositions(in burst: PhotoBurst) {
        moveDispositions(
            burst.frames.map { CullFrameDispositionState(frameURL: $0.url, disposition: nil) }
        )
    }

    func undoLastMove() {
        guard let lastUndoOperation, !isMoving else { return }
        moveDispositions(lastUndoOperation.restoreStates, recordsUndo: false)
    }

    private func moveDisposition(
        of url: URL,
        to disposition: CullDisposition?,
        advanceAfterMove: Bool = false,
        advanceAfterMovingSingleFrame: URL? = nil
    ) {
        moveDispositions(
            [CullFrameDispositionState(frameURL: url, disposition: disposition)],
            advanceAfterMoving: advanceAfterMove ? url : nil,
            advanceAfterMovingSingleFrame: advanceAfterMovingSingleFrame
        )
    }

    private func moveDispositions(
        _ requestedStates: [CullFrameDispositionState],
        recordsUndo: Bool = true,
        advanceAfterMoving frameURL: URL? = nil,
        advanceAfterMovingSingleFrame singleFrameURL: URL? = nil,
        advanceAfterMovingBurst burstID: URL? = nil
    ) {
        guard let folderURL, !isMoving else { return }

        let changedStates = requestedStates.filter {
            dispositions[$0.frameURL] != $0.disposition
        }
        guard !changedStates.isEmpty else {
            if let frameURL, let nextFrameURL = nextFrameURL(after: frameURL) {
                selectedFrameURL = nextFrameURL
            }
            if let singleFrameURL {
                advanceToNextSingleFrame(after: singleFrameURL, replacements: [:])
            }
            if let burstID, let nextBurstID = nextBurstID(after: burstID) {
                selectReviewGroup(withID: .burst(nextBurstID))
            }
            return
        }

        let previousStates = changedStates.map {
            CullFrameDispositionState(frameURL: $0.frameURL, disposition: dispositions[$0.frameURL])
        }
        let relocations = changedStates.map {
            CullFrameRelocation(
                sourceURL: $0.frameURL,
                destinationURL: destinationURL(for: $0.frameURL, disposition: $0.disposition, in: folderURL)
            )
        }
        let relocationCount = relocations.filter { $0.sourceURL != $0.destinationURL }.count
        guard relocationCount > 0 else {
            if let frameURL, let nextFrameURL = nextFrameURL(after: frameURL) {
                selectedFrameURL = nextFrameURL
            }
            if let singleFrameURL {
                advanceToNextSingleFrame(after: singleFrameURL, replacements: [:])
            }
            if let burstID, let nextBurstID = nextBurstID(after: burstID) {
                selectReviewGroup(withID: .burst(nextBurstID))
            }
            return
        }
        let nextFrameURL = frameURL.flatMap { self.nextFrameURL(after: $0) }
        let nextBurstID = burstID.flatMap { self.nextBurstID(after: $0) }

        isMoving = true
        movingFrameCount = relocationCount
        moveErrorMessage = nil

        Task { [weak self] in
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try CullApplyEngine.makePlan(folderURL: folderURL, rawRelocations: relocations)
                }.value
                let result = try await Task.detached(priority: .userInitiated) {
                    try CullApplyEngine.apply(plan)
                }.value

                guard !Task.isCancelled, let self else { return }
                self.rewriteFrameURLs(using: result.rawRelocations)
                self.applyDispositionStates(changedStates, after: result.rawRelocations)
                self.library.applyImageStatistics(after: result, in: folderURL)
                if let nextFrameURL {
                    let destinationBySource = Dictionary(
                        uniqueKeysWithValues: result.rawRelocations.map { ($0.sourceURL, $0.destinationURL) }
                    )
                    self.selectedFrameURL = destinationBySource[nextFrameURL] ?? nextFrameURL
                }
                if let singleFrameURL {
                    let destinationBySource = Dictionary(
                        uniqueKeysWithValues: result.rawRelocations.map { ($0.sourceURL, $0.destinationURL) }
                    )
                    self.advanceToNextSingleFrame(
                        after: singleFrameURL,
                        replacements: destinationBySource
                    )
                }
                if let nextBurstID {
                    self.selectReviewGroup(withID: .burst(nextBurstID))
                }
                self.isMoving = false
                self.movingFrameCount = 0

                if recordsUndo {
                    let destinationBySource = Dictionary(
                        uniqueKeysWithValues: result.rawRelocations.map { ($0.sourceURL, $0.destinationURL) }
                    )
                    let restoreStates = previousStates.compactMap { previousState in
                        destinationBySource[previousState.frameURL].map {
                            CullFrameDispositionState(frameURL: $0, disposition: previousState.disposition)
                        }
                    }
                    self.lastUndoOperation = CullUndoOperation(
                        restoreStates: restoreStates,
                        movedFrameCount: result.rawRelocations.count
                    )
                    self.lastMoveSummary = Self.moveSummary(
                        for: changedStates,
                        companionFileCount: result.companionFileCount
                    )
                } else {
                    self.lastUndoOperation = nil
                    self.lastMoveSummary = "Undid \(result.rawRelocations.count) \(result.rawRelocations.count == 1 ? "move" : "moves")"
                }
            } catch {
                guard let self else { return }
                self.isMoving = false
                self.movingFrameCount = 0
                self.moveErrorMessage = error.localizedDescription
                self.showMoveError = true
            }
        }
    }

    private func nextFrameURL(after frameURL: URL) -> URL? {
        guard let burst = selectedBurst,
              burst.frames.contains(where: { $0.url == frameURL }) else {
            return nil
        }
        return CullFrameNavigation.frameURL(
            in: burst.frames,
            adjacentTo: frameURL,
            offset: 1
        )
    }

    /// In the default All timeline, a decision advances past marked thumbnails
    /// to the next undecided photo. A narrowed filter instead advances within
    /// that filter so a photographer can deliberately review prior choices.
    private func advanceToNextSingleFrame(after sourceURL: URL, replacements: [URL: URL]) {
        guard isReviewingSingles,
              let allFrames = scanResult?.singleFrames,
              !allFrames.isEmpty else {
            return
        }

        let currentURL = replacements[sourceURL] ?? sourceURL
        let currentIndex = allFrames.firstIndex { $0.url == currentURL } ?? -1
        guard currentIndex >= 0 else {
            selectedFrameURL = filteredSingleFrames.first?.url
            return
        }

        let nextFrameURL = CullSingleFrameNavigation.nextFrameURL(
            in: allFrames,
            adjacentTo: currentURL
        ) { candidate in
            if singleFrameFilter == .all {
                return dispositions[candidate.url] == nil
            }
            return singleFrameFilter.includes(dispositions[candidate.url])
        }

        if let nextFrameURL {
            selectedFrameURL = nextFrameURL
            inspectionSource = nil
            isPickingInspectionPoint = false
            automaticallyUseCameraAFTargetForSelectedFrame()
            return
        }

        // All remains visible even after every photo is decided, so retain the
        // final selection for a last confirmation rather than showing an empty
        // queue. Narrow filters retain their existing empty-state behavior.
        selectedFrameURL = singleFrameFilter == .all ? currentURL : nil
        inspectionSource = nil
        isPickingInspectionPoint = false
    }

    private func nextBurstID(after burstID: URL) -> URL? {
        guard let bursts = scanResult?.bursts else { return nil }
        let candidate = CullBurstNavigation.burstID(
            in: bursts,
            adjacentTo: burstID,
            offset: 1
        )
        return candidate == burstID ? nil : candidate
    }

    private func destinationURL(
        for sourceURL: URL,
        disposition: CullDisposition?,
        in folderURL: URL
    ) -> URL {
        let destinationFolder = disposition.map {
            folderURL.appendingPathComponent($0.destinationFolderName, isDirectory: true)
        } ?? folderURL
        return destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)
    }

    private func applyDispositionStates(
        _ states: [CullFrameDispositionState],
        after relocations: [CullFrameRelocation]
    ) {
        let destinationBySource = Dictionary(
            uniqueKeysWithValues: relocations.map { ($0.sourceURL, $0.destinationURL) }
        )
        for state in states {
            let currentURL = destinationBySource[state.frameURL] ?? state.frameURL
            if let disposition = state.disposition {
                dispositions[currentURL] = disposition
            } else {
                dispositions.removeValue(forKey: currentURL)
            }
        }
    }

    private func rewriteFrameURLs(using relocations: [CullFrameRelocation]) {
        let destinationBySource = Dictionary(
            uniqueKeysWithValues: relocations.map { ($0.sourceURL, $0.destinationURL) }
        )
        func rewrittenURL(_ url: URL) -> URL {
            destinationBySource[url] ?? url
        }
        func rewrittenPhoto(_ photo: CullPhoto) -> CullPhoto {
            let updatedURL = rewrittenURL(photo.url)
            return CullPhoto(
                url: updatedURL,
                filename: photo.filename,
                captureDate: photo.captureDate,
                dateSource: photo.dateSource,
                sequenceNumber: photo.sequenceNumber,
                disposition: folderURL.flatMap {
                    CullDisposition.inferred(from: updatedURL, in: $0)
                }
            )
        }

        if let scan = scanResult {
            scanResult = CullFolderScan(
                folder: scan.folder,
                cr3Count: scan.cr3Count,
                unreadableMetadataCount: scan.unreadableMetadataCount,
                bursts: scan.bursts.map { PhotoBurst(frames: $0.frames.map(rewrittenPhoto)) },
                singleFrames: scan.singleFrames.map(rewrittenPhoto),
                duration: scan.duration
            )
        }

        if case let .burst(selectedBurstID) = selectedReviewGroupID {
            destination = .review(.burst(rewrittenURL(selectedBurstID)))
        }
        selectedFrameURL = selectedFrameURL.map(rewrittenURL)
        quickExportSelection.rewrite(using: destinationBySource)
        dispositions = rewriteDictionary(dispositions, using: destinationBySource)
        cameraAFTargets = rewriteDictionary(cameraAFTargets, using: destinationBySource)
        loadedCameraAFTargetURLs = Set(loadedCameraAFTargetURLs.map(rewrittenURL))
        loadingCameraAFTargetURLs = Set(loadingCameraAFTargetURLs.map(rewrittenURL))
    }

    private static func onDiskDispositions(in scan: CullFolderScan) -> [URL: CullDisposition] {
        let frames = scan.bursts.flatMap(\.frames) + scan.singleFrames
        return Dictionary(
            uniqueKeysWithValues: frames.compactMap { frame in
                frame.disposition.map { (frame.url, $0) }
            }
        )
    }

    private func rewriteDictionary<Value>(
        _ dictionary: [URL: Value],
        using replacements: [URL: URL]
    ) -> [URL: Value] {
        Dictionary(uniqueKeysWithValues: dictionary.map { url, value in
            (replacements[url] ?? url, value)
        })
    }

    private static func moveSummary(
        for states: [CullFrameDispositionState],
        companionFileCount: Int
    ) -> String {
        var parts: [String] = []
        let selectCount = states.filter { $0.disposition == .select }.count
        let rejectCount = states.filter { $0.disposition == .reject }.count
        let restoredCount = states.filter { $0.disposition == nil }.count
        if selectCount > 0 { parts.append("\(selectCount) moved to Keeps") }
        if rejectCount > 0 { parts.append("\(rejectCount) moved to Rejects") }
        if restoredCount > 0 { parts.append("\(restoredCount) returned to this date folder") }
        if companionFileCount > 0 {
            parts.append("\(companionFileCount) companion \(companionFileCount == 1 ? "file" : "files") moved")
        }
        return parts.joined(separator: " · ")
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
