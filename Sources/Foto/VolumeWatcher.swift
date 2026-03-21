import Foundation
import AppKit

@Observable
@MainActor
final class VolumeWatcher {
    var lastMountedVolumePath: String?

    private var observer: NSObjectProtocol?

    func startWatching(volumeName: String) {
        stopWatching()
        guard !volumeName.isEmpty else { return }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let path = notification.userInfo?["NSDevicePath"] as? String else { return }
            let mounted = URL(fileURLWithPath: path).lastPathComponent
            if mounted.localizedCaseInsensitiveCompare(volumeName) == .orderedSame {
                Task { @MainActor in
                    self.lastMountedVolumePath = path
                }
            }
        }
    }

    func stopWatching() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    static func ejectVolume(at path: String) async -> Bool {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}
