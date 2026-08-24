import SwiftUI
import AppKit

@main
struct FotocopyApp: App {
    @NSApplicationDelegateAdaptor(FotocopyApplicationDelegate.self) private var appDelegate
    @State private var isChecking = false

    var body: some Scene {
        WindowGroup {
            FotocopyShellView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 700)
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
            }
        }
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
