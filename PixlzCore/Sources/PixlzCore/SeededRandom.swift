/// SplitMix64. Every random choice in the behavior engine goes through one of these,
/// so a test can replay a run from its seed (SPEC §4.3).
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    /// Picks an index with probability proportional to its weight. Nil if every weight is ≤ 0.
    public mutating func weightedIndex(_ weights: [Double]) -> Int? {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return nil }
        var r = Double.random(in: 0..<total, using: &self)
        for (i, w) in weights.enumerated() where w > 0 {
            if r < w { return i }
            r -= w
        }
        return weights.lastIndex { $0 > 0 }
    }
}
