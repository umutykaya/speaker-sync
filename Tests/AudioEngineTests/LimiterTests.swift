import Foundation
import Testing
@testable import AudioEngine

@Suite struct LimiterTests {
    /// Run a 1 kHz stereo sine through the limiter; return the output peak (dBFS) after settling.
    func peakDb(inputDb: Float, ceilingDb: Double?, rate: Double = 48_000) -> (out: Float, reduction: Float) {
        let lim = LimiterControls(count: 1, sampleRate: rate)
        lim.set(output: 0, ceilingDb: ceilingDb)
        let amp = pow(10, inputDb / 20)
        let ceiling = Float(bitPattern: lim.ceilingBits[0].load(ordering: .relaxed))
        var peak: Float = 0
        for n in 0..<Int(rate) {  // 1 s
            var l = amp * Float(sin(2 * .pi * 1000 * Double(n) / rate)), r = l
            if lim.enabled[0].load(ordering: .relaxed) {
                lim.process(output: 0, &l, &r, ceiling: ceiling, state: &lim.state[0])
            }
            if n > Int(rate) / 2 { peak = max(peak, abs(l)) }
            if n % 512 == 511 { lim.publish(output: 0, state: &lim.state[0]) }
        }
        return (20 * log10(peak), lim.takeReductionDb(output: 0))
    }

    @Test func loudSignalHeldUnderCeiling() {
        let r = peakDb(inputDb: 0, ceilingDb: -12)
        #expect(r.out <= -12.0 + 0.01)
        #expect(r.out > -12.5)           // limited, not crushed
        #expect(r.reduction < -11)       // reports ~12 dB of reduction
    }

    @Test func quietSignalUntouched() {
        let r = peakDb(inputDb: -20, ceilingDb: -12)
        #expect(abs(r.out - -20) < 0.01)
        #expect(r.reduction == 0)
    }

    @Test func offMeansNoLimiting() {
        let r = peakDb(inputDb: -3, ceilingDb: nil)
        #expect(abs(r.out - -3) < 0.01)
    }
}
