import AppKit
import PixlMemoryKit
import ServiceManagement

/// Open at login, through macOS's own login items (System Settings ▸ General ▸ Login Items).
@MainActor
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True if macOS took the change (it may ask the user to approve it in System Settings).
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Debug.log("login item \(on ? "on" : "off"): \(SMAppService.mainApp.status.rawValue)")
            return true
        } catch {
            Debug.log("login item: \(error)")
            if on { SMAppService.openSystemSettingsLoginItems() }
            return false
        }
    }
}

/// Starts the local memory service if it isn't running, so opening the app is all a person
/// does: no terminal. The service folder is recorded in the app at build time
/// (Info.plist `PixlMemoryServiceDir`); `uv` runs it. Stopped when the app quits.
@MainActor
final class ServiceLauncher {
    private var process: Process?
    let port = 7341

    var serviceDir: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "PixlMemoryServiceDir") as? String).map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "pyproject.toml").path) ? $0 : nil }
    }

    /// `uv`, wherever the installer or Homebrew put it.
    var uv: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func healthy() async -> Bool {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        r.timeoutInterval = 1.5
        return ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// Starts the service if needed; returns why it couldn't, or nil.
    func ensureRunning() async -> String? {
        if await healthy() { Debug.log("service: already running"); return nil }
        guard let dir = serviceDir else { return "the memory service folder isn't known (reinstall with scripts/install.sh)" }
        guard let uv else { return "uv isn't installed (scripts/install.sh installs it)" }
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/PixlMemory/service.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--quiet", "pixl-memory", "serve"]
        p.currentDirectoryURL = dir
        p.standardOutput = log
        p.standardError = log
        do { try p.run() } catch { return "couldn't start the service: \(error.localizedDescription)" }
        process = p
        Debug.log("service: started pid \(p.processIdentifier) in \(dir.path)")
        for _ in 0..<40 {   // up to ~12 s on a cold start
            try? await Task.sleep(for: .milliseconds(300))
            if await healthy() { Debug.log("service: healthy"); return nil }
            if !p.isRunning { return "the service stopped right away (see ~/Library/Logs/PixlMemory/service.log)" }
        }
        return "the service didn't answer (see ~/Library/Logs/PixlMemory/service.log)"
    }

    /// Only stops the service this app started.
    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        Debug.log("service: stopped")
    }
}
