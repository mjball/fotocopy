import SwiftUI

struct ContentView: View {
    @AppStorage(PreferenceKeys.sourcePath) private var sourcePath = ""
    @AppStorage(PreferenceKeys.destinationPath) private var destinationPath = ""
    @AppStorage(PreferenceKeys.transferMode) private var transferMode = TransferMode.copy.rawValue
    @AppStorage(PreferenceKeys.autoOpenVolume) private var autoOpenVolume = ""
    @AppStorage(PreferenceKeys.ejectSource) private var ejectSource = false
    @AppStorage(PreferenceKeys.ejectDestination) private var ejectDestination = false
    @AppStorage(PreferenceKeys.excludedExtensions) private var excludedExtensionsRaw = ""
    @AppStorage(PreferenceKeys.excludedCameraModels) private var excludedCameraModelsRaw = ""

    @State private var progress = ImportProgress()
    @State private var volumeWatcher = VolumeWatcher()
    @State private var importTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewResult: PreviewResult?
    @State private var isPreviewing = false
    @State private var scanScanned = 0
    @State private var scanTotal = 0
    @State private var showingSettings = false
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var showDateFilter = false

    private var isPhotosLibrarySource: Bool {
        PhotosLibraryResolver.findPhotosLibraryRoot(from: URL(fileURLWithPath: sourcePath)) != nil
    }

    private var excludedExtensions: Set<String> {
        Set(excludedExtensionsRaw.split(separator: ",").map { String($0) })
    }

    private var excludedCameraModels: Set<String> {
        Set(excludedCameraModelsRaw.split(separator: ",").map { String($0) })
    }

    private var activeFilter: ImportFilter {
        ImportFilter(
            excludedExtensions: excludedExtensions,
            excludedCameraModels: excludedCameraModels,
            dateFrom: dateFrom,
            dateTo: dateTo
        )
    }

    private var filteredNewCount: Int {
        previewResult?.filteredCounts(by: activeFilter).new ?? 0
    }

    var body: some View {
        VStack(spacing: 16) {
            pathSection
            modeSection
            if isPreviewing || previewResult != nil {
                previewSection
            }
            actionSection
            if progress.isScanning || progress.isImporting {
                progressSection
            }
            if progress.isComplete {
                completeSection
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        .onChange(of: sourcePath) { _, _ in runPreview() }
        .onChange(of: destinationPath) { _, _ in runPreview() }
        .onChange(of: volumeWatcher.lastMountedVolumePath) { _, newPath in
            if let newPath {
                sourcePath = newPath
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onAppear {
            if !autoOpenVolume.isEmpty {
                volumeWatcher.startWatching(volumeName: autoOpenVolume)
            }
            runPreview()
        }
        .onDisappear {
            volumeWatcher.stopWatching()
            importTask?.cancel()
            previewTask?.cancel()
        }
    }

    private var pathSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Text("Source:")
                    .frame(width: 80, alignment: .trailing)
                HStack {
                    Text(sourcePath.isEmpty ? "Select source folder..." : sourcePath)
                        .truncationMode(.head)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .cornerRadius(4)
                    Button("Browse") { pickFolder(for: \.sourcePath) }
                }
            }
            GridRow {
                Text("Destination:")
                    .frame(width: 80, alignment: .trailing)
                HStack {
                    Text(destinationPath.isEmpty ? "Select destination folder..." : destinationPath)
                        .truncationMode(.head)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .cornerRadius(4)
                    Button("Browse") { pickFolder(for: \.destinationPath) }
                }
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Mode:")
                    .frame(width: 80, alignment: .trailing)
                Picker("", selection: $transferMode) {
                    Text("Copy").tag(TransferMode.copy.rawValue)
                    Text("Move (delete source)").tag(TransferMode.move.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .disabled(isPhotosLibrarySource)
                Spacer()
            }
            if isPhotosLibrarySource {
                HStack {
                    Spacer()
                        .frame(width: 84)
                    Label("Move disabled — would corrupt Photos library", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: sourcePath) { _, _ in
            if isPhotosLibrarySource {
                transferMode = TransferMode.copy.rawValue
            }
        }
    }

    private var actionSection: some View {
        HStack {
            if progress.isImporting {
                Button("Cancel") {
                    importTask?.cancel()
                    importTask = nil
                    progress.isImporting = false
                }
                .tint(.red)
            } else {
                Button("Start Import") {
                    startImport()
                }
                .disabled(sourcePath.isEmpty || destinationPath.isEmpty || isPreviewing || filteredNewCount == 0)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPreviewing {
                VStack(alignment: .leading, spacing: 6) {
                    if scanTotal > 0 {
                        ProgressView(value: Double(scanScanned), total: Double(scanTotal)) {
                            HStack {
                                Text("Scanning \(scanScanned) / \(scanTotal) files")
                                Spacer()
                                Text("\(Int(Double(scanScanned) / Double(scanTotal) * 100))%")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Discovering files...")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            previewTask?.cancel()
                            previewTask = nil
                            isPreviewing = false
                            previewResult = nil
                            scanScanned = 0
                            scanTotal = 0
                        }
                        .controlSize(.small)
                    }
                }
            } else if let preview = previewResult {
                let counts = preview.filteredCounts(by: activeFilter)

                HStack {
                    Label("\(counts.total) files", systemImage: "photo.on.rectangle")
                    Spacer()
                    Text("\(counts.new) new")
                        .foregroundStyle(counts.new > 0 ? .green : .secondary)
                    if counts.duplicates > 0 {
                        Text("\(counts.duplicates) duplicates")
                            .foregroundStyle(.secondary)
                    }
                }

                extensionChips(preview: preview)

                if !preview.cameraModelCounts.isEmpty {
                    cameraModelChips(preview: preview)
                }

                if let range = preview.dateRange {
                    dateRangeRow(range: range)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(8)
    }

    private func extensionChips(preview: PreviewResult) -> some View {
        let counts = preview.extensionCounts
        let sortedExts = counts.sorted { $0.value > $1.value }

        return FlowLayout(spacing: 6) {
            ForEach(sortedExts, id: \.key) { ext, count in
                let isExcluded = excludedExtensions.contains(ext)
                Button {
                    toggleExtension(ext)
                } label: {
                    Text("\(ext.uppercased()) \(count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isExcluded ? .clear : Color.accentColor.opacity(0.15))
                        .foregroundStyle(isExcluded ? .secondary : .primary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(isExcluded ? Color.secondary.opacity(0.3) : Color.accentColor.opacity(0.4), lineWidth: 1)
                        )
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cameraModelChips(preview: PreviewResult) -> some View {
        let counts = preview.cameraModelCounts
        let sorted = counts.sorted { $0.value > $1.value }

        return FlowLayout(spacing: 6) {
            ForEach(sorted, id: \.key) { model, count in
                let isExcluded = excludedCameraModels.contains(model)
                Button {
                    toggleCameraModel(model)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera")
                            .font(.caption2)
                        Text("\(model) \(count)")
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isExcluded ? .clear : Color.accentColor.opacity(0.15))
                    .foregroundStyle(isExcluded ? .secondary : .primary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isExcluded ? Color.secondary.opacity(0.3) : Color.accentColor.opacity(0.4), lineWidth: 1)
                    )
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dateRangeRow(range: (min: Date, max: Date)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(formatDateRange(range.min, range.max))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if dateFrom != nil || dateTo != nil {
                    Button("Clear") {
                        dateFrom = nil
                        dateTo = nil
                        showDateFilter = false
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
                Button(showDateFilter ? "Hide" : "Filter") {
                    showDateFilter.toggle()
                }
                .font(.caption)
                .controlSize(.small)
            }

            if showDateFilter {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("From:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("", selection: Binding(
                            get: { dateFrom ?? range.min },
                            set: { dateFrom = $0 }
                        ), in: range.min...range.max, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    HStack(spacing: 4) {
                        Text("To:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("", selection: Binding(
                            get: { dateTo ?? range.max },
                            set: { dateTo = $0 }
                        ), in: range.min...range.max, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.isScanning {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning files...")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: progress.fraction) {
                    HStack {
                        Text("\(progress.processedFiles) / \(progress.totalFiles) files")
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    if progress.duplicatesSkipped > 0 {
                        Label("\(progress.duplicatesSkipped) duplicates skipped", systemImage: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !progress.fallbackDateFiles.isEmpty {
                        Label("\(progress.fallbackDateFiles.count) used fallback date", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !progress.currentFile.isEmpty {
                    Text(progress.currentFile)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(8)
    }

    private var completeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Complete")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Files imported:")
                        .foregroundStyle(.secondary)
                    Text("\(progress.processedFiles - progress.duplicatesSkipped - progress.errors.count)")
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Duplicates skipped:")
                        .foregroundStyle(.secondary)
                    Text("\(progress.duplicatesSkipped)")
                        .fontWeight(.medium)
                }
                if !progress.errors.isEmpty {
                    GridRow {
                        Text("Errors:")
                            .foregroundStyle(.secondary)
                        Text("\(progress.errors.count)")
                            .fontWeight(.medium)
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.callout)

            if !progress.fallbackDateFiles.isEmpty {
                Label("\(progress.fallbackDateFiles.count) file(s) used filesystem date", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if !progress.errors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Errors", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, error in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(error.file)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(error.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
            }

            HStack {
                if ejectSource || ejectDestination {
                    Button("Eject & Quit") {
                        ejectAndQuit()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                Button("Done") {
                    progress.reset()
                    runPreview()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(8)
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-open when volume mounts:")
                    .font(.callout)
                TextField("Volume name (e.g. SD_CARD)", text: $autoOpenVolume)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to disable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("After import:")
                    .font(.callout)
                Toggle("Eject source volume", isOn: $ejectSource)
                Toggle("Eject destination volume", isOn: $ejectDestination)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Done") {
                    showingSettings = false
                    if !autoOpenVolume.isEmpty {
                        volumeWatcher.startWatching(volumeName: autoOpenVolume)
                    } else {
                        volumeWatcher.stopWatching()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 350)
    }

    private func pickFolder(for keyPath: ReferenceWritableKeyPath<ContentView, String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        let currentPath = self[keyPath: keyPath]
        if !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            self[keyPath: keyPath] = url.path
        }
    }

    private func toggleExtension(_ ext: String) {
        var set = excludedExtensions
        if set.contains(ext) {
            set.remove(ext)
        } else {
            set.insert(ext)
        }
        excludedExtensionsRaw = set.sorted().joined(separator: ",")
    }

    private func toggleCameraModel(_ model: String) {
        var set = excludedCameraModels
        if set.contains(model) {
            set.remove(model)
        } else {
            set.insert(model)
        }
        excludedCameraModelsRaw = set.sorted().joined(separator: ",")
    }

    private func formatDateRange(_ min: Date, _ max: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: min)) — \(formatter.string(from: max))"
    }

    private func runPreview() {
        previewTask?.cancel()
        previewResult = nil

        guard !sourcePath.isEmpty, !destinationPath.isEmpty else { return }
        guard !progress.isImporting, !progress.isComplete else { return }

        isPreviewing = true
        scanScanned = 0
        scanTotal = 0
        let src = URL(fileURLWithPath: sourcePath)
        let dst = URL(fileURLWithPath: destinationPath)

        previewTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()
            let resolver = PhotosLibraryResolver.resolve(for: src)

            do {
                try await checker.buildIndex(at: dst)
                let result = try await engine.previewImport(
                    source: src, duplicateChecker: checker, resolver: resolver,
                    onProgress: { scanned, total in
                        Task { @MainActor in
                            scanScanned = scanned
                            scanTotal = total
                        }
                    }
                )
                if !Task.isCancelled {
                    previewResult = result
                }
            } catch {}

            isPreviewing = false
            scanScanned = 0
            scanTotal = 0
        }
    }

    private func startImport() {
        progress.reset()

        let dst = URL(fileURLWithPath: destinationPath)
        let mode = TransferMode(rawValue: transferMode) ?? .copy
        let filter = activeFilter
        let cachedPreview = previewResult

        previewTask?.cancel()
        previewResult = nil
        isPreviewing = false
        dateFrom = nil
        dateTo = nil
        showDateFilter = false

        importTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()

            do {
                try await checker.buildIndex(at: dst)

                let filesToImport: [PreviewFile]

                if let cachedPreview {
                    filesToImport = cachedPreview.filtered(by: filter)
                } else {
                    let src = URL(fileURLWithPath: sourcePath)
                    let resolver = PhotosLibraryResolver.resolve(for: src)
                    let preview = try await engine.previewImport(
                        source: src, duplicateChecker: checker, resolver: resolver
                    )
                    filesToImport = preview.filtered(by: filter)
                }

                await MainActor.run {
                    progress.totalFiles = filesToImport.count
                    progress.isImporting = true
                }

                try await engine.importFiles(
                    files: filesToImport,
                    destination: dst,
                    mode: mode,
                    duplicateChecker: checker,
                    progress: progress
                )
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        progress.errors.append((file: "Import", message: error.localizedDescription))
                    }
                }
            }

            await MainActor.run {
                progress.isImporting = false
                progress.isComplete = true
                importTask = nil
            }
        }
    }

    private func ejectAndQuit() {
        Task {
            if ejectSource && !sourcePath.isEmpty {
                _ = await VolumeWatcher.ejectVolume(at: sourcePath)
            }
            if ejectDestination && !destinationPath.isEmpty {
                _ = await VolumeWatcher.ejectVolume(at: destinationPath)
            }
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.terminate(nil)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
