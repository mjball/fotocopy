import Foundation
import AppKit

@Observable
@MainActor
final class VolumeWatcher {
    var lastMounted: (path: String, role: String)?

    private var observer: NSObjectProtocol?

    static func volumeName(from path: String) -> String? {
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            if current.deletingLastPathComponent().path == "/Volumes" {
                return current.lastPathComponent
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    func startWatching(volumes: [(name: String, role: String)]) {
        stopWatching()
        guard !volumes.isEmpty else { return }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let path = notification.userInfo?["NSDevicePath"] as? String else { return }
            let mounted = URL(fileURLWithPath: path).lastPathComponent
            for volume in volumes {
                if mounted.localizedCaseInsensitiveCompare(volume.name) == .orderedSame {
                    Task { @MainActor in
                        self.lastMounted = (path: path, role: volume.role)
                    }
                    break
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
