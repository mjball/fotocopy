import SwiftUI

struct ContentView: View {
    @AppStorage(PreferenceKeys.sourcePath) private var sourcePath = ""
    @AppStorage(PreferenceKeys.destinationPath) private var destinationPath = ""
    @AppStorage(PreferenceKeys.transferMode) private var transferMode = TransferMode.copy.rawValue
    @AppStorage(PreferenceKeys.autoOpenVolume) private var autoOpenVolume = ""
    @AppStorage(PreferenceKeys.ejectSource) private var ejectSource = false
    @AppStorage(PreferenceKeys.ejectDestination) private var ejectDestination = false

    @State private var progress = ImportProgress()
    @State private var volumeWatcher = VolumeWatcher()
    @State private var importTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewResult: PreviewResult?
    @State private var isPreviewing = false
    @State private var showingSettings = false

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
        HStack {
            Text("Mode:")
                .frame(width: 80, alignment: .trailing)
            Picker("", selection: $transferMode) {
                Text("Copy").tag(TransferMode.copy.rawValue)
                Text("Move").tag(TransferMode.move.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            Spacer()
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
                .disabled(sourcePath.isEmpty || destinationPath.isEmpty || isPreviewing || previewResult?.newFileCount == 0)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var previewSection: some View {
        HStack(spacing: 12) {
            if isPreviewing {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning...")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    previewTask?.cancel()
                    previewTask = nil
                    isPreviewing = false
                    previewResult = nil
                }
                .controlSize(.small)
            } else if let preview = previewResult {
                Label("\(preview.totalFiles) files found", systemImage: "photo.on.rectangle")
                Spacer()
                Text("\(preview.newFileCount) new")
                    .foregroundStyle(.green)
                if preview.duplicateCount > 0 {
                    Text("\(preview.duplicateCount) duplicates")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .cornerRadius(8)
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

            Divider()

            HStack(spacing: 16) {
                Toggle("Eject source", isOn: $ejectSource)
                Toggle("Eject destination", isOn: $ejectDestination)
            }
            .font(.callout)

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

    private func runPreview() {
        previewTask?.cancel()
        previewResult = nil

        guard !sourcePath.isEmpty, !destinationPath.isEmpty else { return }
        guard !progress.isImporting, !progress.isComplete else { return }

        isPreviewing = true
        let src = URL(fileURLWithPath: sourcePath)
        let dst = URL(fileURLWithPath: destinationPath)

        previewTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()
            let resolver = PhotosLibraryResolver.resolve(for: src)

            do {
                try await checker.buildIndex(at: dst)
                let result = try await engine.previewImport(
                    source: src, duplicateChecker: checker, resolver: resolver
                )
                if !Task.isCancelled {
                    previewResult = result
                }
            } catch {
                // Preview is best-effort; silently ignore errors
            }

            isPreviewing = false
        }
    }

    private func startImport() {
        progress.reset()

        let src = URL(fileURLWithPath: sourcePath)
        let dst = URL(fileURLWithPath: destinationPath)
        let mode = TransferMode(rawValue: transferMode) ?? .copy
        let cachedPreview = previewResult

        previewTask?.cancel()
        previewResult = nil
        isPreviewing = false

        importTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()
            let resolver = PhotosLibraryResolver.resolve(for: src)

            do {
                try await checker.buildIndex(at: dst)

                let files: [URL]
                let preview: PreviewResult?

                if let cachedPreview {
                    files = cachedPreview.files
                    preview = cachedPreview
                } else {
                    progress.isScanning = true
                    files = try await engine.discoverFiles(in: src)
                    progress.isScanning = false
                    preview = nil
                }

                await MainActor.run {
                    progress.totalFiles = files.count
                    progress.isImporting = true
                }

                try await engine.importFiles(
                    files: files,
                    destination: dst,
                    mode: mode,
                    duplicateChecker: checker,
                    progress: progress,
                    previewResult: preview,
                    resolver: resolver
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
