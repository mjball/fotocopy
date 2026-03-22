import SwiftUI

@main
struct FotocopyApp: App {
    @State private var updateState: UpdateState = .idle

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 400)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updateMenuTitle) {
                    checkAndUpdate()
                }
                .disabled(updateState == .checking || updateState == .installing)
                .keyboardShortcut("u", modifiers: .command)
            }
        }
    }

    private var updateMenuTitle: String {
        switch updateState {
        case .idle: "Check for Updates..."
        case .checking: "Checking..."
        case .available(let v): "Update to v\(v)..."
        case .installing: "Installing..."
        case .upToDate: "Up to Date"
        case .error: "Check for Updates..."
        }
    }

    private func checkAndUpdate() {
        switch updateState {
        case .available:
            updateState = .installing
            Task {
                let success = await Updater.installUpdate()
                if !success {
                    await MainActor.run { updateState = .error }
                }
            }
        default:
            updateState = .checking
            Task {
                if let version = await Updater.checkForUpdate() {
                    await MainActor.run { updateState = .available(version) }
                } else {
                    await MainActor.run { updateState = .upToDate }
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run {
                        if case .upToDate = updateState { updateState = .idle }
                    }
                }
            }
        }
    }
}

private enum UpdateState: Equatable {
    case idle
    case checking
    case available(String)
    case installing
    case upToDate
    case error
}
