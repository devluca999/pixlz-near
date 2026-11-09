#!/usr/bin/env swift
// SPEC D7 budget check: measures the running Pixl Memory's own CPU from outside, with the same
// proc_pid_rusage counters the Settings ▸ Energy card uses.
//   swift scripts/bench-energy.swift [seconds]      default 180
// Passive: never changes your settings. Each 10 s window is sorted by the app's debug log into
// idle (nothing happened), moving (an outing or motion) or skipped (you used it).
// Exits 1 if the idle median is 1% of one core or more. Needs a debug build (--debug) for the log.
import Foundation
import Darwin

func pid() -> pid_t? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", "PixlMemory"]
    let out = Pipe(); p.standardOutput = out
    try? p.run(); p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.split(separator: "\n").first.flatMap { pid_t($0) }
}

func cpuNs(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return (info.ri_user_time + info.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
}

/// Log lines since `offset` in the debug log (the app writes one per event).
let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/PixlMemory/debug.log")
func logSize() -> UInt64 { ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? UInt64) ?? 0 }
func logLines(from offset: UInt64) -> [String] {
    guard let h = try? FileHandle(forReadingFrom: logURL) else { return [] }
    defer { try? h.close() }
    try? h.seek(toOffset: offset)
    return String(data: h.readDataToEndOfFile(), encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
}

/// What happened in a window: moving (an outing or any motion), touched (your input: the
/// window doesn't count), or idle (nothing at all).
enum Kind { case idle, moving, touched }
func classify(_ lines: [String]) -> Kind {
    let input = ["mouse", "presence:", "bubble", "hitTest", "hotkey", "mini menu", "typing", "Settings"]
    if lines.contains(where: { l in input.contains { l.contains($0) } }) { return .touched }
    let motion = ["motion start", "display link on", "pond:", "roam: ", "frame "]
    if lines.contains(where: { l in motion.contains { l.contains($0) } && !l.contains("roam: not now") }) { return .moving }
    return .idle
}

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 180
let window = 10.0
guard let p = pid() else { print("Pixl Memory isn't running."); exit(2) }
guard FileManager.default.fileExists(atPath: logURL.path) else { print("No debug log: build with scripts/build-mac-app.sh --debug"); exit(2) }
print("Watching Pixl Memory for \(Int(seconds)) s in \(Int(window)) s windows (your settings are left as they are)…")
var idle: [Double] = [], moving: [Double] = [], touched = 0
let t0 = Date()
while Date().timeIntervalSince(t0) < seconds {
    let off = logSize(), a = cpuNs(p) ?? 0, ta = Date()
    Thread.sleep(forTimeInterval: window)
    let b = cpuNs(p) ?? 0
    let pct = Double(b - a) / 1e9 / Date().timeIntervalSince(ta) * 100
    switch classify(logLines(from: off)) {
    case .idle: idle.append(pct)
    case .moving: moving.append(pct)
    case .touched: touched += 1
    }
}
func median(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.sorted()[xs.count / 2] }
func fmt(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0) } ?? "?" }
print("windows: \(idle.count) idle, \(moving.count) moving, \(touched) skipped (you were using it)")
print(String(format: "idle:   median %@ (%@)", fmt(median(idle)), idle.map { String(format: "%.2f", $0) }.joined(separator: " ")))
print(String(format: "moving: median %@ (%@)", fmt(median(moving)), moving.map { String(format: "%.2f", $0) }.joined(separator: " ")))
print("Typical: \(fmt(median(idle))) CPU idle, \(fmt(median(moving))) while moving")
guard let i = median(idle) else { print("No idle window to judge: run again while you're away from the Mac."); exit(2) }
if i >= 1 { print("Over the SPEC D7 budget (under 1% idle)."); exit(1) }
print("Within the SPEC D7 budget (under 1% idle).")
