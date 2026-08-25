import SwiftUI
import AppKit

@main
struct FotocopyApp: App {
    @NSApplicationDelegateAdaptor(FotocopyApplicationDelegate.self) private var appDelegate
    @State private var isChecking = false
    @State private var cullModel = CullViewModel()
    @State private var cullReviewLayout: CullReviewLayout = .browse
    @AppStorage(PreferenceKeys.activeWorkspace) private var workspaceRaw = FotocopyWorkspace.importPhotos.rawValue

    var body: some Scene {
        WindowGroup {
            FotocopyShellView(cullModel: cullModel, cullReviewLayout: $cullReviewLayout)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 700)

        Settings {
            FotocopySettingsView()
        }

        .commands {
            CommandGroup(after: .appInfo) {
                Button(isChecking ? "Checking..." : "Check for Updates...") {
                    checkForUpdates()
                }
                .disabled(isChecking)
                .keyboardShortcut("u", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Divider()
                Button("Photo Import") {
                    UserDefaults.standard.set(
                        FotocopyWorkspace.importPhotos.rawValue,
                        forKey: PreferenceKeys.activeWorkspace
                    )
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Burst Cull") {
                    UserDefaults.standard.set(
                        FotocopyWorkspace.cullBursts.rawValue,
                        forKey: PreferenceKeys.activeWorkspace
                    )
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Organize Library") {
                    UserDefaults.standard.set(
                        FotocopyWorkspace.organize.rawValue,
                        forKey: PreferenceKeys.activeWorkspace
                    )
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()
                Toggle("Show Camera AF Target", isOn: cameraAFTargetVisibility)
                    .keyboardShortcut("a", modifiers: [.command, .option])
            }

            CullCommands(
                model: cullModel,
                workspace: FotocopyWorkspace(rawValue: workspaceRaw) ?? .importPhotos,
                layout: $cullReviewLayout
            )
        }
    }

    private var cameraAFTargetVisibility: Binding<Bool> {
        Binding(
            get: {
                UserDefaults.standard.object(forKey: PreferenceKeys.cullShowsAFTarget) as? Bool ?? true
            },
            set: {
                UserDefaults.standard.set($0, forKey: PreferenceKeys.cullShowsAFTarget)
            }
        )
    }

    private func checkForUpdates() {
        isChecking = true
        Task {
            let newVersion = await Updater.checkForUpdate()
            await MainActor.run { isChecking = false }

            await MainActor.run {
                if let newVersion {
                    showUpdateAvailable(newVersion)
                } else if newVersion == nil {
                    showUpToDate()
                }
            }
        }
    }

    @MainActor
    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Fotocopy v\(Updater.currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func showUpdateAvailable(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Fotocopy v\(version) is available (you have v\(Updater.currentVersion)). Install now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                let success = await Updater.installUpdate()
                if !success {
                    await MainActor.run { showError() }
                }
            }
        }
    }

    @MainActor
    private func showError() {
        let alert = NSAlert()
        alert.messageText = "Update Failed"
        alert.informativeText = "Could not install the update. Make sure gh is installed and authenticated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Mirrors Cull's on-screen controls in the macOS menu bar. This makes each
/// shortcut discoverable without inventing a second, hidden input vocabulary.
private struct CullCommands: Commands {
    @Bindable var model: CullViewModel
    let workspace: FotocopyWorkspace
    @Binding var layout: CullReviewLayout

    private var isCullActive: Bool {
        workspace == .cullBursts
    }

    private var selectedBurst: PhotoBurst? {
        model.selectedBurst
    }

    private var canReviewBurst: Bool {
        isCullActive &&
            selectedBurst != nil &&
            model.selectedFrameURL != nil &&
            !model.isScanning &&
            !model.isMoving
    }

    private var canUseCameraAFTarget: Bool {
        guard canReviewBurst, let selectedFrameURL = model.selectedFrameURL else { return false }
        return model.cameraAFTarget(for: selectedFrameURL) != nil
    }

    var body: some Commands {
        CommandMenu("Cull") {
            Button("Choose Cull Folder…") {
                model.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!isCullActive || model.isScanning || model.isMoving)

            Menu("Recent Import") {
                if model.recentImportedFolders.isEmpty {
                    Text("No completed Fotocopy import yet")
                } else {
                    ForEach(model.recentImportedFolders, id: \.path) { folder in
                        Button(folder.path) {
                            model.requestUse(folder: folder)
                        }
                    }
                }
            }
            .disabled(!isCullActive || model.isScanning || model.isMoving)

            if model.isScanning {
                Button("Cancel Scan") {
                    model.cancel()
                }
            } else {
                Button("Rescan") {
                    model.scan()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!isCullActive || model.folderURL == nil || model.isMoving)
            }

            Divider()

            Button("Previous Frame") {
                moveFrame(by: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!canReviewBurst)

            Button("Next Frame") {
                moveFrame(by: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!canReviewBurst)

            Button("Previous Burst") {
                model.moveSelectedBurst(by: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!canReviewBurst)

            Button("Next Burst") {
                model.moveSelectedBurst(by: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!canReviewBurst)

            Divider()

            Button("Keep Current Frame") {
                model.keepSelectedFrame()
            }
            .keyboardShortcut("k", modifiers: [])
            .disabled(!canReviewBurst)

            Button("Reject Current Frame") {
                model.rejectSelectedFrame()
            }
            .keyboardShortcut("x", modifiers: [])
            .disabled(!canReviewBurst)

            Button("Keep Current, Reject Rest") {
                keepCurrentAndRejectRest()
            }
            .keyboardShortcut("k", modifiers: .shift)
            .disabled(!canReviewBurst)

            Button("Reject All in Burst") {
                rejectBurst()
            }
            .keyboardShortcut("x", modifiers: .shift)
            .disabled(!canReviewBurst)

            Divider()

            Button("Keep All in Burst") {
                keepBurst()
            }
            .disabled(!canReviewBurst)

            Button("Clear Burst Marks") {
                clearBurstMarks()
            }
            .disabled(!canReviewBurst)

            Button("Undo Last Cull Move") {
                model.undoLastMove()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!isCullActive || !model.canUndoLastMove)

            Divider()

            Button("Reveal Cull Folder in Finder") {
                model.revealFolder()
            }
            .disabled(!isCullActive || model.folderURL == nil)

            Button("Reveal Selected Frame in Finder") {
                model.revealSelectedFrame()
            }
            .disabled(!canReviewBurst)

            Divider()

            Menu("Review Layout") {
                ForEach(CullReviewLayout.allCases) { candidate in
                    Button(candidate.title) {
                        layout = candidate
                    }
                }
            }
            .disabled(!isCullActive || model.folderURL == nil)

            Button("Use Camera AF Target") {
                model.useCameraAFTarget()
            }
            .disabled(!canUseCameraAFTarget)

            Button("Pick Detail Manually") {
                model.beginPickingInspectionPoint()
            }
            .disabled(!canReviewBurst)

            Button("Clear Inspection Target") {
                model.clearInspectionPoint()
            }
            .disabled(!canReviewBurst || model.inspectionSource == nil)
        }
    }

    private func moveFrame(by offset: Int) {
        guard let selectedBurst else { return }
        model.moveSelectedFrame(in: selectedBurst, by: offset)
    }

    private func keepCurrentAndRejectRest() {
        guard let selectedBurst else { return }
        model.keepSelectedAndRejectRest(in: selectedBurst)
    }

    private func rejectBurst() {
        guard let selectedBurst else { return }
        model.markAllRejecting(in: selectedBurst)
    }

    private func keepBurst() {
        guard let selectedBurst else { return }
        model.markAllKeeping(in: selectedBurst)
    }

    private func clearBurstMarks() {
        guard let selectedBurst else { return }
        model.clearDispositions(in: selectedBurst)
    }
}
