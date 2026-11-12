import Darwin
import Foundation

// Claude Code runs this for each hook (SPEC §16.1): it hands the event to Pixl Memory over
// a Unix socket and prints the app's answer, if any. When the app isn't running it prints
// nothing, and Claude Code carries on as if there were no hook. Always exits 0.

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let object = try? JSONSerialization.jsonObject(with: input),
      var line = try? JSONSerialization.data(withJSONObject: object) else { exit(0) }
line.append(0x0A)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
// the app's socket (AgentSocket.path in PixlAgents; spelled out so this helper links nothing but Foundation)
let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/PixlMemory/agents.sock").path
_ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(0) }

// A permission request may wait for you (up to 55 s in the app), and a finished turn (Stop) for
// your reply (the reply window, at most 300 s); everything else is answered at once.
let event = (object as? [String: Any])?["hook_event_name"] as? String
// Every other event (PostToolUse carrying your message too) never slows Claude down: 1 s at most.
var wait = timeval(tv_sec: event == "Stop" ? 325 : event == "PermissionRequest" ? 58 : 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
var sent = 0
while sent < line.count {
    let n = line.withUnsafeBytes { write(fd, $0.baseAddress! + sent, line.count - sent) }
    if n <= 0 { exit(0) }
    sent += n
}

var reply = Data()
var buf = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    reply.append(contentsOf: buf[0..<n])
}
close(fd)
if !reply.isEmpty { FileHandle.standardOutput.write(reply) }
exit(0)
