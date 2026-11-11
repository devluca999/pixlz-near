import Foundation

/// PIXL_DEBUG=1 (or launching with --debug) logs every mouse event Frogg receives and every
/// menu open/select, to ~/Library/Logs/PixlMemory/debug.log and stderr:
///
///     tail -f ~/Library/Logs/PixlMemory/debug.log
///
/// Never logs selected text, suggestions or keys: only event kinds and ids.
public enum Debug {
    public nonisolated(unsafe) static var enabled: Bool =
        ProcessInfo.processInfo.environment["PIXL_DEBUG"] == "1" || CommandLine.arguments.contains("--debug")

    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/PixlMemory/debug.log")

    private static let queue = DispatchQueue(label: "pixl.debug")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    public static func log(_ message: @autoclosure () -> String, file: StaticString = #fileID) {
        guard enabled else { return }
        let line = "\(day.string(from: Date())) \(stamp.string(from: Date())) [\(String(describing: file).split(separator: "/").last ?? "")] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Kept across launches and installs; past 5 MB the older half moves to debug.1.log.
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
                let old = dir.appending(path: "debug.1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
