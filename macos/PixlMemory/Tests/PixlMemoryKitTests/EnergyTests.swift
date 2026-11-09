import Testing
import Foundation
@testable import PixlMemoryKit

@Suite struct EnergyTests {
    @Test func readsThisProcess() throws {
        let a = try #require(EnergyReading.now())
        #expect(a.footprint > 1_000_000)   // a running test process uses more than 1 MB
        var x = 0.0
        for i in 0..<2_000_000 { x += sin(Double(i)) }   // burn a little CPU
        #expect(x.isFinite)
        let b = try #require(EnergyReading.now())
        #expect(b.cpuNs > a.cpuNs)
    }

    @Test func sampleMathIsPercentOfOneCore() throws {
        let a = EnergyReading(cpuNs: 0, footprint: 0, energyNj: 0, at: 100)
        let b = EnergyReading(cpuNs: 30_000_000, footprint: 50 * 1_048_576, energyNj: 20_000_000, at: 110)   // 30 ms of CPU in 10 s
        let s = try #require(EnergySample(from: a, to: b))
        #expect(abs(s.cpu - 0.3) < 1e-9)
        #expect(s.memoryMB == 50)
        #expect(abs((s.milliwatts ?? 0) - 2) < 1e-9)
        #expect(EnergySample(from: b, to: b) == nil)
    }

    @Test func historyKeepsTenMinutesAndDrawsASparkline() {
        var h = EnergyHistory()
        for t in stride(from: 0.0, through: 1200, by: 60) { h.add(EnergySample(cpu: t > 1100 ? 4 : 0.2, memoryMB: 40, milliwatts: nil, at: t)) }
        #expect(h.samples.allSatisfy { 1200 - $0.at <= 600 })
        let bars = h.sparkline(bars: 60, height: 12)
        #expect(bars.count == 60)
        #expect(bars.last == 12)                       // 4 % is above the 2 % full scale: clipped
        #expect(bars.contains(2))                      // 0.2 % shows as a small bar, not nothing
        #expect(bars.allSatisfy { (0...12).contains($0) })
    }

    @Test func plainEnglish() {
        #expect(EnergyHistory.sentence(cpu: 0.3) == "Using 0.3% CPU, lighter than a browser tab.")
        #expect(EnergyHistory.sentence(cpu: 0.04) == "Using less than 0.1% CPU, lighter than a browser tab.")
        #expect(EnergyHistory.sentence(cpu: 2).contains("music app"))
    }
}
