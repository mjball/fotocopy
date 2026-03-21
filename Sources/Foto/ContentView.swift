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
    @State private var showingSummary = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 16) {
            pathSection
            modeSection
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
        .sheet(isPresented: $showingSummary) {
            SummaryView(progress: progress)
        }
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
        }
        .onDisappear {
            volumeWatcher.stopWatching()
            importTask?.cancel()
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
                .disabled(sourcePath.isEmpty || destinationPath.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
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
        VStack(spacing: 12) {
            Button("View Summary") {
                showingSummary = true
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
        if panel.runModal() == .OK, let url = panel.url {
            self[keyPath: keyPath] = url.path
        }
    }

    private func startImport() {
        progress.reset()
        progress.isScanning = true

        let src = URL(fileURLWithPath: sourcePath)
        let dst = URL(fileURLWithPath: destinationPath)
        let mode = TransferMode(rawValue: transferMode) ?? .copy

        importTask = Task {
            let engine = ImportEngine()
            let checker = DuplicateChecker()

            do {
                try await checker.buildIndex(at: dst)
                let files = try await engine.discoverFiles(in: src)

                await MainActor.run {
                    progress.totalFiles = files.count
                    progress.isScanning = false
                    progress.isImporting = true
                }

                try await engine.importFiles(
                    files: files,
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
