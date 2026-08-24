import Foundation
import AppKit

enum VolumeRole: String, Equatable, Sendable {
    case source
    case destination
}

/// The portion of a configured path below a mounted volume's root.
struct VolumeRelativePath: Equatable, Sendable {
    let components: [String]

    init?(components: [String]) {
        guard components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.contains("/")
        }) else {
            return nil
        }
        self.components = components
    }

    func appending(to mountURL: URL) -> URL {
        components.reduce(mountURL) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }
    }
}

/// A saved source or destination that can be restored when its volume remounts.
struct VolumeBinding: Equatable, Sendable {
    let role: VolumeRole
    let volumeName: String
    let mountDirectoryName: String
    let relativePath: VolumeRelativePath

    var mountRootPath: String {
        URL(fileURLWithPath: "/Volumes")
            .appendingPathComponent(mountDirectoryName, isDirectory: true)
            .path
    }

    init?(role: VolumeRole, configuredPath: String, volumeName: String? = nil) {
        let standardizedURL = URL(fileURLWithPath: configuredPath).standardizedFileURL
        let components = standardizedURL.pathComponents

        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes",
              !components[2].isEmpty,
              let relativePath = VolumeRelativePath(components: Array(components.dropFirst(3))) else {
            return nil
        }

        let identityName = volumeName ?? components[2]
        guard !identityName.isEmpty, !identityName.contains("/") else { return nil }

        self.role = role
        self.volumeName = identityName
        self.mountDirectoryName = components[2]
        self.relativePath = relativePath
    }

    func restoredPath(mountedAt mountPath: String, mountedVolumeName: String?) -> String? {
        let mountURL = URL(fileURLWithPath: mountPath).standardizedFileURL
        let mountComponents = mountURL.pathComponents

        // A mount notification should name the root of a volume, never a folder within it.
        guard mountComponents.count == 3,
              mountComponents[0] == "/",
              mountComponents[1] == "Volumes" else {
            return nil
        }

        // The filesystem's volume name is authoritative when it is available. The
        // mount-directory suffix is only a fallback for volumes whose name cannot be read.
        let nameToMatch = mountedVolumeName ?? mountComponents[2]
        guard nameToMatch.localizedCaseInsensitiveCompare(volumeName) == .orderedSame else {
            return nil
        }

        return relativePath.appending(to: mountURL).path
    }
}

struct MountedVolume: Equatable {
    let path: String
    let role: VolumeRole
}

@Observable
@MainActor
final class VolumeWatcher {
    var lastMounted: [MountedVolume] = []

    private var observer: NSObjectProtocol?

    func startWatching(bindings: [VolumeBinding]) {
        stopWatching()
        guard !bindings.isEmpty else { return }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let mountPath = notification.userInfo?["NSDevicePath"] as? String else { return }

            let restoredVolumes = Self.restoredVolumes(
                forMountAt: mountPath,
                mountedVolumeName: Self.logicalVolumeName(at: mountPath),
                bindings: bindings
            )
            guard !restoredVolumes.isEmpty else { return }

            Task { @MainActor in
                self.lastMounted = restoredVolumes
            }
        }
    }

    func stopWatching() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    nonisolated static func restoredVolumes(
        forMountAt mountPath: String,
        mountedVolumeName: String?,
        bindings: [VolumeBinding]
    ) -> [MountedVolume] {
        bindings.compactMap { binding in
            guard let path = binding.restoredPath(
                mountedAt: mountPath,
                mountedVolumeName: mountedVolumeName
            ) else {
                return nil
            }
            return MountedVolume(path: path, role: binding.role)
        }
    }

    nonisolated static func logicalVolumeName(at mountPath: String) -> String? {
        let mountURL = URL(fileURLWithPath: mountPath)
        return try? mountURL.resourceValues(forKeys: [.volumeNameKey]).volumeName
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
