import AppKit
import ImageIO
import SwiftUI

struct CullWorkspaceView: View {
    @Bindable var model: CullViewModel

    var body: some View {
        detail
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("Recent Import") {
                    if model.recentImportedFolders.isEmpty {
                        Text("No completed Fotocopy import yet")
                    } else {
                        ForEach(model.recentImportedFolders, id: \.path) { folder in
                            Button(folder.path) { model.requestUse(folder: folder) }
                        }
                    }
                }
                    .disabled(model.isScanning || model.isApplying)

                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isScanning || model.isApplying)

                if model.isScanning {
                    Button("Cancel") { model.cancel() }
                } else if model.folderURL != nil {
                    Button("Scan Again") { model.scan() }
                        .disabled(model.isApplying)
                }
            }
        }
        .alert("Could not scan folder", isPresented: $model.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .alert(model.applyConfirmationTitle, isPresented: $model.showApplyConfirmation) {
            Button(model.applyButtonLabel) { model.applyConfirmedChanges() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(model.applyConfirmationMessage)
        }
        .confirmationDialog(
            "Apply or discard cull changes?",
            isPresented: $model.showPendingChangesConfirmation,
            titleVisibility: .visible
        ) {
            Button(model.applyButtonLabel) { model.applyPendingChangesAndContinue() }
            Button("Discard changes", role: .destructive) { model.discardPendingChangesAndContinue() }
            Button("Cancel", role: .cancel) { model.cancelPendingChangesConfirmation() }
        } message: {
            Text("\(model.applyConfirmationMessage) You can also discard these local marks; nothing has moved yet.")
        }
        .alert("Could not apply cull changes", isPresented: $model.showApplyError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.applyErrorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.isScanning {
            ContentUnavailableView(
                "Finding bursts",
                systemImage: "rectangle.stack.badge.play",
                description: Text("Fotocopy reads only the selected folder and leaves all files untouched."))
        } else if let burst = model.selectedBurst {
            BurstReviewView(burst: burst, model: model)
        } else if let scan = model.scanResult, scan.cr3Count == 0 {
            ContentUnavailableView(
                "No CR3 files in this folder",
                systemImage: "camera.metering.none",
                description: Text("Cull currently reviews CR3 files directly in one selected destination folder."))
        } else if let scan = model.scanResult, scan.bursts.isEmpty {
            ContentUnavailableView(
                "No bursts found",
                systemImage: "rectangle.stack",
                description: Text("Fotocopy kept the grouping conservative. Try another destination day folder or inspect the single frames in Finder."))
        } else {
            ContentUnavailableView(
                "Choose a destination folder",
                systemImage: "folder.badge.magnifyingglass",
                description: Text("It will group consecutive CR3 captures for manual review, without creating a library."))
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

            Button("Choose Folder…") { model.chooseFolder() }
                .disabled(model.isScanning || model.isApplying)

            Menu("Recent Import") {
                if model.recentImportedFolders.isEmpty {
                    Text("No completed Fotocopy import yet")
                } else {
                    ForEach(model.recentImportedFolders, id: \.path) { folder in
                            Button(folder.path) { model.requestUse(folder: folder) }
                    }
                }
            }
            .disabled(model.isScanning || model.isApplying)

            Picker("Scan workers", selection: $model.workerCount) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("4").tag(4)
                Text("6").tag(6)
            }
            .disabled(model.isScanning || model.isApplying)
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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(burst.title)
                                .lineLimit(1)
                            Text("\(burst.frames.count) frames · \(captureRangeLabel(for: burst))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(FotocopySidebarDestination.burst(burst.id))
                    }
                }
            }

            if !scan.singleFrames.isEmpty {
                Section("Single frames") {
                    Text("\(scan.singleFrames.count) not grouped into a burst")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if model.folderURL != nil {
            Section {
                Button("Reveal Folder in Finder") { model.revealFolder() }
            }
        }
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
}

private struct BurstReviewView: View {
    let burst: PhotoBurst
    @Bindable var model: CullViewModel

    private var selectedFrame: CullPhoto? {
        burst.frames.first { $0.url == model.selectedFrameURL } ?? burst.frames.first
    }

    private var selectedFramePosition: Int {
        guard let selectedFrame,
              let index = burst.frames.firstIndex(of: selectedFrame) else { return 1 }
        return index + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(burst.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("\(burst.frames.count) related frames · frame \(selectedFramePosition) of \(burst.frames.count)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal Selected") { model.revealSelectedFrame() }
                    .disabled(selectedFrame == nil)
            }

            if let selectedFrame {
                HStack(alignment: .top, spacing: 18) {
                    CullInspectionPreviewView(
                        url: selectedFrame.url,
                        inspectionPoint: model.inspectionPoint,
                        cameraAFTarget: model.cameraAFTarget(for: selectedFrame.url),
                        isPickingInspectionPoint: model.isPickingInspectionPoint,
                        onInspectionPointSelected: model.setInspectionPoint
                    )
                    .id(selectedFrame.url)
                    .frame(maxWidth: .infinity, minHeight: 430, maxHeight: 540)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(selectedFrame.filename)
                            .font(.headline)
                        Text(captureLabel(selectedFrame))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Button(model.isKeeping(selectedFrame.url) ? "Marked to keep" : "Mark to keep") {
                            model.toggleKeeping(selectedFrame.url)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(model.isRejecting(selectedFrame.url) ? "Marked as reject" : "Mark as reject") {
                            model.toggleRejecting(selectedFrame.url)
                        }
                        .buttonStyle(.bordered)

                        Divider()

                        if model.isLoadingCameraAFTarget(for: selectedFrame.url) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Reading camera AF data…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if let target = model.cameraAFTarget(for: selectedFrame.url) {
                            Label("Camera AF target · \(target.state.displayName)", systemImage: "viewfinder")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if !model.isUsingCameraAFTarget {
                                Button("Use camera AF target") {
                                    model.useCameraAFTarget()
                                }
                                .buttonStyle(.bordered)
                            }
                        } else if model.hasLoadedCameraAFTarget(for: selectedFrame.url) {
                            Text("No active camera AF target recorded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button(model.isPickingInspectionPoint ? "Click the preview…" : "Pick detail manually") {
                            model.beginPickingInspectionPoint()
                        }
                        .buttonStyle(.bordered)

                        if model.inspectionSource != nil {
                            Button("Clear inspection target") {
                                model.clearInspectionPoint()
                            }
                            .buttonStyle(.link)
                        }

                        Text(inspectionHint(for: model))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Marks stay local until Apply. Applied selects and rejects move into matching subfolders; unmarked frames stay here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 230, alignment: .leading)
                }
            }

            HStack {
                Text("Frames")
                    .font(.headline)
                Spacer()
                Button("Keep all") { model.markAllKeeping(in: burst) }
                Button("Reject all") { model.markAllRejecting(in: burst) }
                Button("Clear selection") { model.clearKeeping(in: burst) }
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(burst.frames) { frame in
                        Button {
                            model.selectFrame(frame.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                CullPreviewView(url: frame.url, size: .thumbnail)
                                    .frame(width: 142, height: 106)
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
                    }
                }
                .padding(.bottom, 4)
            }

            if let inspectionSource = model.inspectionSource {
                CullInspectionCropSection(
                    burst: burst,
                    inspectionSource: inspectionSource,
                    model: model
                )
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Subject-local review", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                    Text("Fotocopy will use an active camera AF target when the file records one, or you can pick a detail manually. Fotocopy still does not choose or discard frames for you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if let summary = model.lastApplySummary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        model.hasPendingCullChanges
                            ? "Changes have not been applied yet."
                            : "Mark explicit selects or rejects; unmarked frames stay in place.",
                        systemImage: model.hasPendingCullChanges ? "exclamationmark.circle" : "hand.point.up.left"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.applyButtonLabel) { model.requestApply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasPendingCullChanges || model.isApplying)
            }
        }
        .padding(24)
        .task(id: burst.id) {
            model.loadCameraAFTargets(in: burst)
            await Task.detached(priority: .utility) {
                CullPreviewCache.shared.prefetch(burst.frames.map(\.url))
            }.value
        }
        .background {
            CullFrameNavigationKeyHandler { offset in
                model.moveSelectedFrame(in: burst, by: offset)
            }
            .frame(width: 0, height: 0)
        }
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

private enum CullPreviewSize {
    case thumbnail
    case large

    var maxPixelSize: Int {
        switch self {
        case .thumbnail: return 640
        case .large: return 1_600
        }
    }
}

private struct CullPreviewView: View {
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

    @State private var image: NSImage?
    @State private var didFail = false
    @State private var fullPreview: NSImage?
    @State private var fullPreviewDidFail = false
    @State private var committedZoom: CGFloat = 1
    @GestureState private var gestureMagnification: CGFloat = 1

    private var effectiveZoom: CGFloat {
        min(max(committedZoom * gestureMagnification, 1), 6)
    }

    private var fullPreviewRequestID: String {
        effectiveZoom > 1.02 ? "\(url.path)#full-preview" : ""
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
            fullPreviewDidFail = false
            committedZoom = 1
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
                  !fullPreviewDidFail else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                CullPreviewCache.shared.fullPreview(for: url)
            }.value
            guard !Task.isCancelled else { return }
            fullPreview = loaded
            fullPreviewDidFail = loaded == nil
        }
        .onChange(of: isPickingInspectionPoint) { _, isPicking in
            if isPicking {
                committedZoom = 1
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
        let canvasSize = CGSize(
            width: max(geometry.size.width, zoomedSize.width),
            height: max(geometry.size.height, zoomedSize.height)
        )
        let imageRect = CullInspectionGeometry.fittedImageRect(
            imageSize: image.size,
            in: canvasSize
        )

        ZStack(alignment: .topTrailing) {
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)

                    if let inspectionPoint {
                        Circle()
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.black.opacity(0.38)))
                            .shadow(radius: 2)
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
                        Text("Click a subject detail")
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
                .frame(width: canvasSize.width, height: canvasSize.height)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard isPickingInspectionPoint,
                                  let point = CullInspectionGeometry.normalizedPoint(
                                    for: value.location,
                                    imageSize: image.size,
                                    in: canvasSize
                                  ) else { return }
                            onInspectionPointSelected(point)
                        }
                )
            }
            .background(.black)
            .simultaneousGesture(magnificationGesture)
            .onTapGesture(count: 2) {
                guard !isPickingInspectionPoint else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    committedZoom = effectiveZoom > 1.02 ? 1 : 2
                }
            }

            if effectiveZoom > 1.02, fullPreview == nil, !fullPreviewDidFail {
                Label("Loading full JPEG preview…", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .padding(8)
                    .background(.black.opacity(0.72), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .updating($gestureMagnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                committedZoom = min(max(committedZoom * value.magnification, 1), 6)
            }
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
                    Text(inspectionSource == .cameraAF ? "Camera-AF crops" : "Inspection-point crops")
                        .font(.headline)
                    Text(cropDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Manual comparison")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(burst.frames) { frame in
                        Button {
                            model.selectFrame(frame.url)
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
                    }
                }
                .padding(.bottom, 4)
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

    private var cropDescription: String {
        switch inspectionSource {
        case .manual:
            return "The same normalized image area from each frame, extracted from its large embedded JPEG preview."
        case .cameraAF:
            return "The camera-recorded active AF area for each frame, extracted from its large embedded JPEG preview."
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
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    model.selectedFrameURL == frame.url ? Color.accentColor : Color.clear,
                    lineWidth: 3
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
/// photographer is reviewing. A local monitor keeps plain left/right arrows
/// dedicated to the current burst without stealing shortcuts or text editing.
private struct CullFrameNavigationKeyHandler: NSViewRepresentable {
    let move: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(move: move)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.move = move
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var move: (Int) -> Void
        private var monitor: Any?

        init(move: @escaping (Int) -> Void) {
            self.move = move
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      !Self.isEditingText(in: event.window),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }

                switch event.keyCode {
                case 123: // left arrow
                    self.move(-1)
                    return nil
                case 124: // right arrow
                    self.move(1)
                    return nil
                default:
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

@Observable
@MainActor
final class CullViewModel {
    var folderURL: URL?
    var workerCount = 4
    var scanResult: CullFolderScan?
    var isScanning = false
    var progressCompleted = 0
    var progressTotal = 0
    var currentFilename = ""
    var errorMessage: String?
    var showError = false
    var applyErrorMessage: String?
    var showApplyError = false
    var showApplyConfirmation = false
    var showPendingChangesConfirmation = false
    var isApplying = false
    var lastApplySummary: String?
    var selectedBurstID: URL?
    var selectedFrameURL: URL?
    var inspectionSource: CullInspectionSource?
    var isPickingInspectionPoint = false
    private(set) var dispositions: [URL: CullDisposition] = [:]
    private(set) var cameraAFTargets: [URL: CameraAFTarget] = [:]
    private(set) var loadedCameraAFTargetURLs: Set<URL> = []
    private(set) var loadingCameraAFTargetURLs: Set<URL> = []

    private var scanTask: Task<Void, Never>?
    private var pendingContinuation: (() -> Void)?
    private var pendingCancellation: (() -> Void)?

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

    var selectedBurst: PhotoBurst? {
        scanResult?.bursts.first { $0.id == selectedBurstID }
    }

    var hasPendingCullChanges: Bool { !dispositions.isEmpty }
    var selectCount: Int { dispositions.values.filter { $0 == .select }.count }
    var rejectCount: Int { dispositions.values.filter { $0 == .reject }.count }
    var markedFrameCount: Int { dispositions.count }

    var applyConfirmationTitle: String {
        "Apply \(markedFrameCount) cull \(markedFrameCount == 1 ? "change" : "changes")?"
    }

    var applyConfirmationMessage: String {
        let moves = [
            selectCount > 0 ? "\(selectCount) to Selects" : nil,
            rejectCount > 0 ? "\(rejectCount) to Rejects" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " and ")
        return "This moves \(moves). Every unmarked frame stays where it is. Nothing is deleted."
    }

    var applyButtonLabel: String {
        "Move \(markedFrameCount) \(markedFrameCount == 1 ? "frame" : "frames")"
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
        panel.message = "Choose one Fotocopy destination folder containing CR3 photos. Fotocopy only moves explicit selects or rejects after you confirm Apply."
        if let folderURL {
            panel.directoryURL = folderURL
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestUse(folder: url)
    }

    func requestUse(folder: URL) {
        requestContinuation { [weak self] in
            self?.use(folder: folder)
        }
    }

    private func use(folder: URL) {
        folderURL = folder
        UserDefaults.standard.set(folder.path, forKey: PreferenceKeys.lastCullFolder)
        startScan()
    }

    func scan() {
        requestContinuation { [weak self] in
            self?.startScan()
        }
    }

    private func startScan() {
        guard let folderURL, !isScanning else { return }
        scanTask?.cancel()
        scanResult = nil
        dispositions.removeAll()
        selectedBurstID = nil
        selectedFrameURL = nil
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
        let workers = workerCount
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
                selectedBurstID = result.bursts.first?.id
                selectedFrameURL = result.bursts.first?.frames.first?.url
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

    func requestLeavingCull(
        onContinue: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        requestContinuation(onContinue, onCancel: onCancel)
    }

    func requestApply() {
        guard hasPendingCullChanges, !isApplying else { return }
        showApplyConfirmation = true
    }

    func applyConfirmedChanges() {
        showApplyConfirmation = false
        applyMarkedFrames(then: pendingContinuation)
    }

    func applyPendingChangesAndContinue() {
        showPendingChangesConfirmation = false
        applyMarkedFrames(then: pendingContinuation)
    }

    func discardPendingChangesAndContinue() {
        dispositions.removeAll()
        finishPendingContinuation()
    }

    func cancelPendingChangesConfirmation() {
        showPendingChangesConfirmation = false
        let cancellation = pendingCancellation
        pendingContinuation = nil
        pendingCancellation = nil
        cancellation?()
    }

    private func requestContinuation(
        _ continuation: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        guard hasPendingCullChanges else {
            continuation()
            return
        }
        pendingContinuation = continuation
        pendingCancellation = onCancel
        showPendingChangesConfirmation = true
    }

    private func applyMarkedFrames(then continuation: (() -> Void)?) {
        guard let folderURL, hasPendingCullChanges, !isApplying else { return }

        let markedDispositions = dispositions
        isApplying = true
        applyErrorMessage = nil

        Task { [weak self] in
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try CullApplyEngine.makePlan(
                        folderURL: folderURL,
                        dispositions: markedDispositions
                    )
                }.value
                let result = try await Task.detached(priority: .userInitiated) {
                    try CullApplyEngine.apply(plan)
                }.value

                guard !Task.isCancelled, let self else { return }
                self.dispositions.removeAll()
                self.isApplying = false
                self.lastApplySummary = Self.applySummary(for: result)
                if continuation != nil {
                    self.finishPendingContinuation()
                } else {
                    self.startScan()
                }
            } catch {
                guard let self else { return }
                self.isApplying = false
                self.applyErrorMessage = error.localizedDescription
                self.showApplyError = true
            }
        }
    }

    private func finishPendingContinuation() {
        let continuation = pendingContinuation
        pendingContinuation = nil
        pendingCancellation = nil
        continuation?()
    }

    private static func applySummary(for result: CullApplyResult) -> String {
        var parts: [String] = []
        if result.selectCount > 0 { parts.append("\(result.selectCount) moved to Selects") }
        if result.rejectCount > 0 { parts.append("\(result.rejectCount) moved to Rejects") }
        if result.companionFileCount > 0 {
            parts.append("\(result.companionFileCount) companion \(result.companionFileCount == 1 ? "file" : "files") moved")
        }
        return parts.joined(separator: " · ")
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

    func selectFrame(_ url: URL) {
        selectedFrameURL = url
    }

    func moveSelectedFrame(in burst: PhotoBurst, by offset: Int) {
        selectedFrameURL = CullFrameNavigation.frameURL(
            in: burst.frames,
            adjacentTo: selectedFrameURL,
            offset: offset
        )
    }

    func beginPickingInspectionPoint() {
        isPickingInspectionPoint = true
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

    private func automaticallyUseCameraAFTarget(for burst: PhotoBurst) {
        guard inspectionSource == nil,
              selectedBurstID == burst.id,
              let selectedFrameURL,
              cameraAFTargets[selectedFrameURL] != nil else {
            return
        }
        inspectionSource = .cameraAF
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
        lastApplySummary = nil
        if isKeeping(url) {
            dispositions.removeValue(forKey: url)
        } else {
            dispositions[url] = .select
        }
    }

    func toggleRejecting(_ url: URL) {
        lastApplySummary = nil
        if isRejecting(url) {
            dispositions.removeValue(forKey: url)
        } else {
            dispositions[url] = .reject
        }
    }

    func markAllKeeping(in burst: PhotoBurst) {
        lastApplySummary = nil
        for frame in burst.frames {
            dispositions[frame.url] = .select
        }
    }

    func markAllRejecting(in burst: PhotoBurst) {
        lastApplySummary = nil
        for frame in burst.frames {
            dispositions[frame.url] = .reject
        }
    }

    func clearKeeping(in burst: PhotoBurst) {
        for frame in burst.frames {
            dispositions.removeValue(forKey: frame.url)
        }
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

private final class CullPreviewCache: @unchecked Sendable {
    static let shared = CullPreviewCache()

    private let previews = NSCache<NSString, NSImage>()
    private let fullPreviews = NSCache<NSURL, NSImage>()
    private let focusCrops = NSCache<NSString, NSImage>()

    /// Crop extraction can require decoding a much larger embedded JPEG than a
    /// normal cull preview. Keep that I/O bounded so a long burst does not
    /// overwhelm a slower external drive or inflate memory all at once.
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

    func fullPreview(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = fullPreviews.object(forKey: key) { return cached }
        guard let image = image(for: url, maxPixelSize: 16_384) else { return nil }
        fullPreviews.setObject(image, forKey: key, cost: imageCost(image))
        return image
    }

    func focusCrop(for url: URL, around point: CullInspectionPoint) -> NSImage? {
        let key = "\(url.path)#focus#\(point.cacheKey)" as NSString
        if let cached = focusCrops.object(forKey: key) { return cached }

        focusCropGate.wait()
        defer { focusCropGate.signal() }

        // Another visible crop can have completed while this task was waiting.
        if let cached = focusCrops.object(forKey: key) { return cached }

        // This is intentionally larger than the main preview, but the decoded
        // image is immediately reduced to a small crop and is never retained.
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
