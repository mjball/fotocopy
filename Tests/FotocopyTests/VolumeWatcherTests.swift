import Testing
import Foundation
@testable import Fotocopy

@Suite
struct VolumeWatcherTests {
    @Test func restoresBARDestinationAtItsExistingManifestPath() throws {
        let binding = try #require(VolumeBinding(
            role: .destination,
            configuredPath: "/Volumes/BAR/Fotocopy"
        ))

        #expect(binding.relativePath.components == ["Fotocopy"])
        let restoredPath = binding.restoredPath(mountedAt: "/Volumes/BAR", mountedVolumeName: "BAR")
        #expect(restoredPath == "/Volumes/BAR/Fotocopy")
        #expect(DestinationManifest(destinationURL: URL(fileURLWithPath: try #require(restoredPath))).databaseURL.path == "/Volumes/BAR/Fotocopy/metadata/fotocopy-manifest.sqlite")
    }

    @Test func restoresDCIMPath() throws {
        let binding = try #require(VolumeBinding(
            role: .source,
            configuredPath: "/Volumes/EOS_CF/DCIM"
        ))

        #expect(binding.restoredPath(mountedAt: "/Volumes/EOS_CF", mountedVolumeName: "EOS_CF") == "/Volumes/EOS_CF/DCIM")
    }

    @Test func restoresVolumeRootWithoutGuessingSubpath() throws {
        let binding = try #require(VolumeBinding(
            role: .source,
            configuredPath: "/Volumes/BAR"
        ))

        #expect(binding.relativePath.components.isEmpty)
        #expect(binding.restoredPath(mountedAt: "/Volumes/BAR", mountedVolumeName: "BAR") == "/Volumes/BAR")
    }

    @Test func restoresMultiLevelPath() throws {
        let binding = try #require(VolumeBinding(
            role: .destination,
            configuredPath: "/Volumes/Archive/Photos/2026/Italy"
        ))

        #expect(binding.relativePath.components == ["Photos", "2026", "Italy"])
        #expect(binding.restoredPath(mountedAt: "/Volumes/Archive", mountedVolumeName: "Archive") == "/Volumes/Archive/Photos/2026/Italy")
    }

    @Test func rejectsPathsOutsideAVolumeRoot() {
        #expect(VolumeBinding(role: .source, configuredPath: "/Users/me/DCIM") == nil)
        #expect(VolumeBinding(role: .source, configuredPath: "/Volumes") == nil)
        #expect(VolumeBinding(role: .source, configuredPath: "/Volumes/BAR/../../tmp") == nil)
    }

    @Test func usesLogicalVolumeNameWhenMountDirectoryDiffers() throws {
        let binding = try #require(VolumeBinding(
            role: .destination,
            configuredPath: "/Volumes/BAR 1/Fotocopy",
            volumeName: "BAR"
        ))

        #expect(binding.mountRootPath == "/Volumes/BAR 1")
        #expect(binding.restoredPath(mountedAt: "/Volumes/BAR 1", mountedVolumeName: "BAR") == "/Volumes/BAR 1/Fotocopy")
    }

    @Test func logicalVolumeNameDoesNotFallBackToConflictingDirectoryName() throws {
        let binding = try #require(VolumeBinding(
            role: .source,
            configuredPath: "/Volumes/BAR/DCIM"
        ))

        #expect(binding.restoredPath(mountedAt: "/Volumes/BAR", mountedVolumeName: "Other Disk") == nil)
    }

    @Test func restoresSourceAndDestinationIndependently() throws {
        let source = try #require(VolumeBinding(
            role: .source,
            configuredPath: "/Volumes/CARD/DCIM"
        ))
        let destination = try #require(VolumeBinding(
            role: .destination,
            configuredPath: "/Volumes/CARD/Fotocopy"
        ))

        let restored = VolumeWatcher.restoredVolumes(
            forMountAt: "/Volumes/CARD",
            mountedVolumeName: "CARD",
            bindings: [source, destination]
        )

        #expect(restored == [
            MountedVolume(path: "/Volumes/CARD/DCIM", role: .source),
            MountedVolume(path: "/Volumes/CARD/Fotocopy", role: .destination)
        ])
    }
}
