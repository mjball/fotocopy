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

    @State private var vm = ImportViewModel()
    @State private var volumeWatcher = VolumeWatcher()
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 16) {
            pathSection
            modeSection
            if vm.isPreviewing || vm.previewResult != nil || vm.previewError != nil {
                previewSection
            }
            actionSection
            if vm.progress.isScanning || vm.progress.isImporting {
                progressSection
            }
            if vm.progress.isComplete {
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
        .onChange(of: sourcePath) { _, _ in syncAndPreview() }
        .onChange(of: destinationPath) { _, _ in syncAndPreview() }
        .onChange(of: excludedExtensionsRaw) { _, new in vm.excludedExtensionsRaw = new }
        .onChange(of: excludedCameraModelsRaw) { _, new in vm.excludedCameraModelsRaw = new }
        .onChange(of: transferMode) { _, new in vm.transferMode = new }
        .onChange(of: volumeWatcher.lastMountedVolumePath) { _, newPath in
            if let newPath {
                sourcePath = newPath
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onAppear {
            vm.sourcePath = sourcePath
            vm.destinationPath = destinationPath
            vm.transferMode = transferMode
            vm.excludedExtensionsRaw = excludedExtensionsRaw
            vm.excludedCameraModelsRaw = excludedCameraModelsRaw
            if !autoOpenVolume.isEmpty {
                volumeWatcher.startWatching(volumeName: autoOpenVolume)
            }
            vm.runPreview()
        }
        .onDisappear {
            volumeWatcher.stopWatching()
            vm.cleanup()
        }
    }

    private func syncAndPreview() {
        vm.sourcePath = sourcePath
        vm.destinationPath = destinationPath
        if vm.isPhotosLibrarySource {
            transferMode = TransferMode.copy.rawValue
        }
        vm.runPreview()
    }

    // MARK: - Path section

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

    // MARK: - Mode section

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
                .disabled(vm.isPhotosLibrarySource)
                Spacer()
            }
            if vm.isPhotosLibrarySource {
                HStack {
                    Spacer()
                        .frame(width: 84)
                    Label("Move disabled — would corrupt Photos library", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Action section

    private var actionSection: some View {
        VStack(spacing: 4) {
            HStack {
                if vm.progress.isImporting {
                    Button("Cancel") { vm.cancelImport() }
                        .tint(.red)
                } else {
                    Button("Import") {
                        if let spaceError = vm.checkDiskSpace() {
                            let alert = NSAlert()
                            alert.messageText = "Not enough disk space"
                            alert.informativeText = spaceError
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                            return
                        }
                        vm.startImport()
                    }
                    .disabled(vm.isImportDisabled)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            if let reason = vm.importDisabledReason, !vm.progress.isImporting, !vm.progress.isComplete {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Preview section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.isPreviewing {
                VStack(alignment: .leading, spacing: 6) {
                    if vm.scanTotal > 0 {
                        ProgressView(value: Double(vm.scanScanned), total: Double(vm.scanTotal)) {
                            HStack {
                                Text("Scanning \(vm.scanScanned) / \(vm.scanTotal) files")
                                Spacer()
                                Text("\(Int(Double(vm.scanScanned) / Double(vm.scanTotal) * 100))%")
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
                        Button("Cancel") { vm.cancelPreview() }
                            .controlSize(.small)
                    }
                }
            } else if let error = vm.previewError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let preview = vm.previewResult {
                let counts = vm.filteredCounts

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
        let sortedExts = preview.extensionCounts.sorted { $0.value > $1.value }

        return FlowLayout(spacing: 6) {
            ForEach(sortedExts, id: \.key) { ext, count in
                let isExcluded = vm.excludedExtensions.contains(ext)
                Button { vm.toggleExtension(ext) } label: {
                    chipLabel(text: "\(ext.uppercased()) \(count)", isExcluded: isExcluded)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cameraModelChips(preview: PreviewResult) -> some View {
        let sorted = preview.cameraModelCounts.sorted { $0.value > $1.value }

        return FlowLayout(spacing: 6) {
            ForEach(sorted, id: \.key) { model, count in
                let isExcluded = vm.excludedCameraModels.contains(model)
                Button { vm.toggleCameraModel(model) } label: {
                    chipLabel(text: "\(model) \(count)", isExcluded: isExcluded, icon: "camera")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chipLabel(text: String, isExcluded: Bool, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
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
                if vm.dateFrom != nil || vm.dateTo != nil {
                    Button("Clear") {
                        vm.dateFrom = nil
                        vm.dateTo = nil
                        vm.showDateFilter = false
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
                Button(vm.showDateFilter ? "Hide" : "Filter") {
                    vm.showDateFilter.toggle()
                }
                .font(.caption)
                .controlSize(.small)
            }

            if vm.showDateFilter {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("From:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("", selection: Binding(
                            get: { vm.dateFrom ?? range.min },
                            set: { vm.dateFrom = $0 }
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
                            get: { vm.dateTo ?? range.max },
                            set: { vm.dateTo = $0 }
                        ), in: range.min...range.max, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Progress section

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.progress.isScanning {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning files...")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: vm.progress.fraction) {
                    HStack {
                        Text("\(vm.progress.processedFiles) / \(vm.progress.totalFiles) files")
                        Spacer()
                        Text("\(Int(vm.progress.fraction * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    if vm.progress.duplicatesSkipped > 0 {
                        Label("\(vm.progress.duplicatesSkipped) duplicates skipped", systemImage: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !vm.progress.fallbackDateFiles.isEmpty {
                        Label("\(vm.progress.fallbackDateFiles.count) used fallback date", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !vm.progress.currentFile.isEmpty {
                    Text(vm.progress.currentFile)
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

    // MARK: - Complete section

    private var completeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Complete")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Files imported:")
                        .foregroundStyle(.secondary)
                    Text("\(vm.progress.processedFiles - vm.progress.duplicatesSkipped - vm.progress.errors.count)")
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Duplicates skipped:")
                        .foregroundStyle(.secondary)
                    Text("\(vm.progress.duplicatesSkipped)")
                        .fontWeight(.medium)
                }
                if !vm.progress.errors.isEmpty {
                    GridRow {
                        Text("Errors:")
                            .foregroundStyle(.secondary)
                        Text("\(vm.progress.errors.count)")
                            .fontWeight(.medium)
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.callout)

            if !vm.progress.fallbackDateFiles.isEmpty {
                Label("\(vm.progress.fallbackDateFiles.count) file(s) used filesystem date", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if !vm.progress.errors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Errors", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(vm.progress.errors.enumerated()), id: \.offset) { _, error in
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
                Button("Done") { vm.resetAndPreview() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Settings sheet

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

    // MARK: - Helpers

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

    private func formatDateRange(_ min: Date, _ max: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: min)) — \(formatter.string(from: max))"
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
        arrange(proposal: proposal, subviews: subviews).size
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
