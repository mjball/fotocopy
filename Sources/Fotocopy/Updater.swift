import Foundation
import AppKit

enum Updater {
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    static func checkForUpdate() async -> String? {
        guard let output = runGH(["release", "view", "--repo", "mjball/fotocopy", "--json", "tagName", "-q", ".tagName"]) else {
            return nil
        }
        let latest = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
        if latest.isEmpty { return nil }
        return latest != currentVersion ? latest : nil
    }

    static func installUpdate() async -> Bool {
        let appPath = Bundle.main.bundlePath
        let appName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")

        guard let tmpDir = runCommand("/usr/bin/mktemp", ["-d"]) else { return false }
        let tmp = tmpDir.trimmingCharacters(in: .whitespacesAndNewlines)

        guard runGH(["release", "download", "--repo", "mjball/fotocopy", "--pattern", "\(appName).app.zip", "--dir", tmp]) != nil else {
            return false
        }

        let script = """
            set -e
            unzip -q "\(tmp)/\(appName).app.zip" -d "\(tmp)"
            xattr -cr "\(tmp)/\(appName).app"
            rm -rf "\(appPath)"
            mv "\(tmp)/\(appName).app" "\(appPath)"
            rm -rf "\(tmp)"
            sleep 0.5
            open "\(appPath)"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            return false
        }

        await MainActor.run {
            NSApp.terminate(nil)
        }
        return true
    }

    @discardableResult
    private static func runGH(_ args: [String]) -> String? {
        let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        guard let ghPath = ghPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        return runCommand(ghPath, args)
    }

    private static func runCommand(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
