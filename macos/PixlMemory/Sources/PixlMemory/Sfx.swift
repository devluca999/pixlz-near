import AVFoundation
import PixlMemoryKit

/// Short, soft sound effects for payoffs (a tongue snap, a gulp, a ding…), synthesized here: no
/// audio files. Off unless Sounds is on in Settings (Showcase mode turns them on for a take).
@MainActor
final class Sfx {
    static let shared = Sfx()

    enum Sound: String, CaseIterable { case pop, ding, snap, gulp, chime, coin, thud, ribbit, alert, whoosh, sparkle }

    /// Settings ▸ Sounds (and Showcase mode). Off by default.
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "PixlMemory.sounds") || forced }
        set { UserDefaults.standard.set(newValue, forKey: "PixlMemory.sounds") }
    }
    var forced = false
    var volume: Float = 0.32

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var started = false

    func play(_ s: Sound) {
        guard enabled else { return }
        if !started { start() }
        guard started, let buf = buffer(s) else { return }
        let p = players[next % players.count]
        next += 1
        p.stop()
        p.volume = volume
        p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        p.play()
    }

    private func start() {
        for _ in 0..<6 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        do { try engine.start(); started = true } catch { Debug.log("sfx: audio engine didn't start: \(error)") }
    }

    private func buffer(_ s: Sound) -> AVAudioPCMBuffer? {
        if let b = buffers[s] { return b }
        let b = Self.synth(s, format: format)
        buffers[s] = b
        return b
    }

    /// Each sound as a short envelope over a few partials or a sweep.
    static func synth(_ s: Sound, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        func make(_ seconds: Double, _ f: (Double) -> Double) -> AVAudioPCMBuffer? {
            let n = AVAudioFrameCount(seconds * sr)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let d = b.floatChannelData?[0] else { return nil }
            b.frameLength = n
            for i in 0..<Int(n) {
                let t = Double(i) / sr
                let fadeIn = min(1, t / 0.004), fadeOut = min(1, (seconds - t) / 0.01)
                d[i] = Float(max(-1, min(1, f(t))) * fadeIn * fadeOut)
            }
            return b
        }
        func tone(_ hz: Double, _ t: Double) -> Double { sin(2 * .pi * hz * t) }
        var seed: UInt64 = 0x9E37_79B9
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(Int64(bitPattern: seed >> 1) % 2000) / 1000 - 1 }
        switch s {
        case .pop:      // a soft bubble pop: a quick upward chirp
            return make(0.09) { t in tone(520 + 2600 * t, t) * exp(-t * 38) * 0.8 }
        case .ding:     // a bright bell
            return make(0.9) { t in (tone(1318.5, t) + 0.45 * tone(2637, t) + 0.2 * tone(3951, t)) * exp(-t * 4.2) * 0.45 }
        case .snap:     // the tongue: a click and a short zip
            return make(0.11) { t in (noise() * exp(-t * 90) * 0.5 + tone(1800 - 9000 * t, t) * exp(-t * 30) * 0.5) }
        case .gulp:     // a low downward bloop
            return make(0.22) { t in tone(320 - 900 * t, t) * sin(.pi * min(1, t / 0.22)) * 0.8 }
        case .chime:    // saved: two rising notes
            return make(0.42) { t in (t < 0.12 ? tone(880, t) : tone(1318.5, t)) * exp(-(t < 0.12 ? t : t - 0.12) * 9) * 0.5 }
        case .coin:     // a coin: two high notes, very quick
            return make(0.32) { t in (t < 0.07 ? tone(1975.5, t) : tone(2637, t)) * exp(-(t < 0.07 ? t * 6 : (t - 0.07) * 10)) * 0.45 }
        case .thud:     // a soft landing
            return make(0.16) { t in tone(95 - 160 * t, t) * exp(-t * 22) * 0.9 }
        case .ribbit:   // a small red alert croak: two buzzy chirps
            return make(0.34) { t in
                let on = (t < 0.13) || (t > 0.18 && t < 0.31)
                return on ? (tone(330, t) > 0 ? 0.45 : -0.45) * (0.6 + 0.4 * tone(32, t)) : 0
            }
        case .alert:    // two short beeps
            return make(0.3) { t in ((t < 0.1) || (t > 0.16 && t < 0.26)) ? tone(1046.5, t) * 0.4 : 0 }
        case .whoosh:   // a hop or an entrance
            return make(0.25) { t in noise() * sin(.pi * t / 0.25) * 0.22 }
        case .sparkle:  // twinkles
            return make(0.35) { t in (tone(2093, t) * 0.5 + tone(3136, t) * 0.3) * (0.5 + 0.5 * tone(24, t)) * exp(-t * 7) * 0.45 }
        }
    }
}
