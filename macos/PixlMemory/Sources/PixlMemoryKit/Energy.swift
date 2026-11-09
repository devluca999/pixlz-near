import AppKit
import Darwin

/// How little Pixl Memory uses (Settings ▸ Energy). Reads the app's own counters with
/// proc_pid_rusage: CPU time, memory footprint and (on Apple silicon) energy. One read is a
/// single syscall, so sampling every few seconds costs next to nothing.
public struct EnergyReading: Equatable, Sendable {
    public var cpuNs: UInt64          // user + system CPU time, nanoseconds
    public var footprint: UInt64      // physical footprint, bytes
    public var energyNj: UInt64?      // energy used so far, nanojoules (nil where not reported)
    public var at: TimeInterval       // wall clock, seconds

    public init(cpuNs: UInt64, footprint: UInt64, energyNj: UInt64?, at: TimeInterval) {
        self.cpuNs = cpuNs; self.footprint = footprint; self.energyNj = energyNj; self.at = at
    }

    /// This process now.
    public static func now() -> EnergyReading? {
        var info = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        guard ok == 0 else { return nil }
        // rusage CPU times are in mach absolute time units: convert to nanoseconds
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = info.ri_user_time + info.ri_system_time
        let ns = tb.denom == 0 ? ticks : ticks * UInt64(tb.numer) / UInt64(tb.denom)
        return EnergyReading(cpuNs: ns, footprint: info.ri_phys_footprint, energyNj: info.ri_energy_nj > 0 ? info.ri_energy_nj : nil,
                             at: Date().timeIntervalSince1970)
    }
}

/// One sample between two readings.
public struct EnergySample: Equatable, Sendable {
    public var cpu: Double            // percent of one core
    public var memoryMB: Double
    public var milliwatts: Double?
    public var at: TimeInterval

    /// The sample between readings `a` and `b` (nil if no time passed).
    public init?(from a: EnergyReading, to b: EnergyReading) {
        let dt = b.at - a.at
        guard dt > 0.05, b.cpuNs >= a.cpuNs else { return nil }
        cpu = Double(b.cpuNs - a.cpuNs) / 1e9 / dt * 100
        memoryMB = Double(b.footprint) / 1_048_576
        if let e0 = a.energyNj, let e1 = b.energyNj, e1 >= e0 { milliwatts = Double(e1 - e0) / 1e6 / dt } else { milliwatts = nil }
        at = b.at
    }

    public init(cpu: Double, memoryMB: Double, milliwatts: Double?, at: TimeInterval) {
        self.cpu = cpu; self.memoryMB = memoryMB; self.milliwatts = milliwatts; self.at = at
    }
}

/// The last ~10 minutes of samples, and the plain-English summary.
public struct EnergyHistory: Sendable {
    public static let window: TimeInterval = 600
    public private(set) var samples: [EnergySample] = []
    public init() {}

    public mutating func add(_ s: EnergySample) {
        samples.append(s)
        samples.removeAll { s.at - $0.at > Self.window }
    }

    public var average: Double? { samples.isEmpty ? nil : samples.map(\.cpu).reduce(0, +) / Double(samples.count) }
    public var latest: EnergySample? { samples.last }

    /// "Using 0.3% CPU, lighter than a browser tab."
    public static func sentence(cpu: Double) -> String {
        let pct = cpu < 0.1 ? "less than 0.1%" : String(format: "%.1f%%", cpu)
        switch cpu {
        case ..<1: return "Using \(pct) CPU, lighter than a browser tab."
        case ..<5: return "Using \(pct) CPU, about like a music app."
        default: return "Using \(pct) CPU right now, while it's on the move."
        }
    }

    /// Bar heights (0…`height`) for a sparkline `bars` wide, oldest first; a 2 % CPU full scale
    /// so idle wiggles show, clipped above.
    public func sparkline(bars: Int, height: Int) -> [Int] {
        guard !samples.isEmpty, bars > 0 else { return Array(repeating: 0, count: max(bars, 0)) }
        let end = samples.last!.at, start = end - Self.window
        var out = Array(repeating: 0, count: bars)
        for i in 0..<bars {
            let a = start + Double(i) / Double(bars) * Self.window, b = start + Double(i + 1) / Double(bars) * Self.window
            let inBin = samples.filter { $0.at > a && $0.at <= b }
            guard !inBin.isEmpty else { continue }
            let v = inBin.map(\.cpu).max()!
            out[i] = max(1, min(height, Int((v / 2 * Double(height)).rounded(.up))))
        }
        return out
    }
}

/// The Energy card's sparkline: pixel bars in the accent colour on a faint baseline.
@MainActor
public final class EnergySparkline: NSView {
    public var bars: [Int] = [] { didSet { needsDisplay = true } }
    let look: SurfaceView.Look
    public static let barCount = 60, maxHeight = 12
    public init(look: SurfaceView.Look) {
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(Self.barCount) * 3, height: CGFloat(Self.maxHeight) * 2 + 2))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: frame.width).isActive = true
        heightAnchor.constraint(equalToConstant: frame.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("CPU over the last 10 minutes")
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { false }
    public override func draw(_ dirtyRect: NSRect) {
        look.tokens.line.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        Accent.color.setFill()
        for (i, h) in bars.enumerated() where h > 0 {
            NSRect(x: CGFloat(i) * 3, y: 2, width: 2, height: CGFloat(h) * 2).fill()   // 2 pt pixels
        }
    }
}

/// Samples the app: once a minute in the background (for the long-run average) and every few
/// seconds while Settings is open (for the live line and the sparkline).
@MainActor
public final class EnergyMonitor {
    public static let shared = EnergyMonitor()
    public private(set) var history = EnergyHistory()
    /// Since launch: CPU time over wall time, the honest long-run average.
    public private(set) var sinceLaunch: Double?
    public var onSample: ((EnergyHistory) -> Void)?
    var first: EnergyReading?
    var last: EnergyReading?
    var background: Timer?
    var live: Timer?
    public static let backgroundInterval: TimeInterval = 60, liveInterval: TimeInterval = 3

    public init() {}

    public func start() {
        guard background == nil else { return }
        first = EnergyReading.now(); last = first
        background = Timer.scheduledTimer(withTimeInterval: Self.backgroundInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        background?.tolerance = 10   // let macOS coalesce the wake
    }

    /// Settings opened (true) or closed (false).
    public func setLive(_ on: Bool) {
        live?.invalidate(); live = nil
        guard on else { return }
        sample()
        live = Timer.scheduledTimer(withTimeInterval: Self.liveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        live?.tolerance = 0.5
    }

    public func sample() {
        guard let now = EnergyReading.now() else { return }
        if let last, let s = EnergySample(from: last, to: now) { history.add(s) }
        if let first, now.at - first.at > 1 { sinceLaunch = Double(now.cpuNs - first.cpuNs) / 1e9 / (now.at - first.at) * 100 }
        last = now
        onSample?(history)
    }
}
