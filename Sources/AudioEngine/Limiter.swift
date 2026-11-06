import Foundation
import Synchronization

/// Optional per-speaker peak limiter: holds one speaker's output under a
/// ceiling (dBFS of the signal sent to it) without touching the other speaker.
/// Instant attack (no overshoot, no lookahead) and a smooth release, so quiet
/// passages are unchanged and only loud peaks are turned down.
///
/// Control side writes atomics; the render thread owns `LimiterState`.
public final class LimiterControls: @unchecked Sendable {
    let count: Int
    let enabled: UnsafeMutablePointer<Atomic<Bool>>
    let ceilingBits: UnsafeMutablePointer<Atomic<UInt32>>
    /// Deepest gain reduction (linear) since the last read; 1 = not limiting.
    let reductionBits: UnsafeMutablePointer<Atomic<UInt32>>
    let state: UnsafeMutablePointer<LimiterState>
    let release: Float

    init(count: Int, sampleRate: Double) {
        self.count = count
        enabled = .allocate(capacity: count)
        ceilingBits = .allocate(capacity: count)
        reductionBits = .allocate(capacity: count)
        state = .allocate(capacity: count)
        for i in 0..<count {
            (enabled + i).initialize(to: Atomic(false))
            (ceilingBits + i).initialize(to: Atomic(Float(1).bitPattern))
            (reductionBits + i).initialize(to: Atomic(Float(1).bitPattern))
            state[i] = LimiterState()
        }
        release = Float(1 - exp(-1 / (0.150 * sampleRate)))  // ~150 ms recovery
    }

    /// nil turns the limiter off for that output.
    func set(output: Int, ceilingDb: Double?) {
        if let db = ceilingDb {
            ceilingBits[output].store(Float(pow(10, min(max(db, -60), 0) / 20)).bitPattern, ordering: .relaxed)
            enabled[output].store(true, ordering: .relaxed)
        } else {
            enabled[output].store(false, ordering: .relaxed)
        }
    }

    /// Deepest reduction in dB (<= 0) since the last call; 0 when not limiting.
    func takeReductionDb(output: Int) -> Float {
        let g = Float(bitPattern: reductionBits[output].exchange(Float(1).bitPattern, ordering: .relaxed))
        return g < 1 ? 20 * log10(max(g, 1e-6)) : 0
    }

    /// Render thread: limit one stereo frame in place.
    @inline(__always)
    func process(output o: Int, _ l: inout Float, _ r: inout Float, ceiling: Float, state s: inout LimiterState) {
        let peak = max(abs(l), abs(r))
        let target: Float = peak > ceiling ? ceiling / peak : 1
        if target < s.gain { s.gain = target } else { s.gain += (target - s.gain) * release }
        l *= s.gain
        r *= s.gain
        if s.gain < s.minGain { s.minGain = s.gain }
    }

    /// Render thread: publish the deepest reduction of this cycle.
    @inline(__always)
    func publish(output o: Int, state s: inout LimiterState) {
        if s.minGain < 1 {
            let prev = Float(bitPattern: reductionBits[o].load(ordering: .relaxed))
            if s.minGain < prev { reductionBits[o].store(s.minGain.bitPattern, ordering: .relaxed) }
        }
        s.minGain = 1
    }
}

public struct LimiterState {
    var gain: Float = 1
    var minGain: Float = 1
}
