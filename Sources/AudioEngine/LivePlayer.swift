import CoreAudio
import Synchronization

/// Plays live input (a process tap inside the aggregate) to the speakers.
/// One IOProc on the aggregate receives the tap's input and writes all speaker
/// outputs in the same cycle, so input and outputs share one timeline. Each
/// speaker reads a ring buffer at (write position - its delay).
///
/// Real-time rules as in Player: no locks, allocation or I/O in the IOProc.
public final class LivePlayer {
    public static let maxOutputs = 8
    static let ringFrames = 1 << 18          // ~5.9 s at 44.1 kHz: covers 2000 ms delay with margin
    static let ringMask = ringFrames - 1
    static let delayFadeFrames = 1440

    public let sampleRate: Double
    public let outputs: [Player.OutputMap]
    private let aggregateID: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    // Control -> RT
    public let muted = Atomic<Bool>(false)
    public let masterGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let delayTarget: UnsafeMutablePointer<Atomic<Int>>
    private let gainBits: UnsafeMutablePointer<Atomic<UInt32>>
    // RT -> control
    /// Peak input level since the last `takeInputPeak()`; 0 means silence
    /// (nothing playing, or the System Audio Recording permission is missing).
    private let inputPeakBits = Atomic<UInt32>(0)
    public let cycles = Atomic<Int>(0)
    /// Last seen input layout: buffers * 1000 + channels in the first buffer (diagnostic).
    public let inputLayout = Atomic<Int>(0)

    // RT-only state
    private let outCount: Int
    private let ringL: UnsafeMutablePointer<Float>
    private let ringR: UnsafeMutablePointer<Float>
    private var writePos = 0
    private let rtDelayCur: UnsafeMutablePointer<Int>
    private let rtDelayOld: UnsafeMutablePointer<Int>
    private let rtFadePos: UnsafeMutablePointer<Int>
    private let rtGain: UnsafeMutablePointer<Float>
    private var rtMaster: Float = 0
    private let smoothing: Float
    private let limiter: LimiterControls

    public init(aggregateID: AudioObjectID, sampleRate: Double, outputs: [Player.OutputMap]) {
        precondition(!outputs.isEmpty && outputs.count <= LivePlayer.maxOutputs)
        self.aggregateID = aggregateID
        self.sampleRate = sampleRate
        self.outputs = outputs
        outCount = outputs.count
        smoothing = Float(1 - exp(-1 / (0.010 * sampleRate)))
        limiter = LimiterControls(count: outputs.count, sampleRate: sampleRate)
        ringL = .allocate(capacity: LivePlayer.ringFrames)
        ringR = .allocate(capacity: LivePlayer.ringFrames)
        ringL.initialize(repeating: 0, count: LivePlayer.ringFrames)
        ringR.initialize(repeating: 0, count: LivePlayer.ringFrames)
        delayTarget = .allocate(capacity: outCount)
        gainBits = .allocate(capacity: outCount)
        rtDelayCur = .allocate(capacity: outCount)
        rtDelayOld = .allocate(capacity: outCount)
        rtFadePos = .allocate(capacity: outCount)
        rtGain = .allocate(capacity: outCount)
        for i in 0..<outCount {
            (delayTarget + i).initialize(to: Atomic(0))
            (gainBits + i).initialize(to: Atomic(Float(1).bitPattern))
            rtDelayCur[i] = 0
            rtDelayOld[i] = 0
            rtFadePos[i] = LivePlayer.delayFadeFrames
            rtGain[i] = 1
        }
    }

    // MARK: control API

    public func setDelay(output: Int, ms: Double) {
        let frames = Int((ms / 1000 * sampleRate).rounded())
        delayTarget[output].store(min(max(frames, 0), LivePlayer.ringFrames / 2), ordering: .relaxed)
    }
    public func delayMs(output: Int) -> Double {
        Double(delayTarget[output].load(ordering: .relaxed)) / sampleRate * 1000
    }
    public func setGain(output: Int, _ g: Float) { gainBits[output].store(min(max(g, 0), 1).bitPattern, ordering: .relaxed) }
    public func gain(output: Int) -> Float { Float(bitPattern: gainBits[output].load(ordering: .relaxed)) }
    public func setMaster(_ g: Float) { masterGainBits.store(min(max(g, 0), 1).bitPattern, ordering: .relaxed) }
    public var master: Float { Float(bitPattern: masterGainBits.load(ordering: .relaxed)) }
    /// Per-speaker peak limiter; nil turns it off.
    public func setLimiter(output: Int, ceilingDb: Double?) { limiter.set(output: output, ceilingDb: ceilingDb) }
    public func takeLimiterReductionDb(output: Int) -> Float { limiter.takeReductionDb(output: output) }
    public func takeInputPeak() -> Float { Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed)) }

    public func start() throws {
        var id: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&id, aggregateID, nil) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }
        guard status == noErr, let id else { throw PrivateAggregate.Failure(description: "AudioDeviceCreateIOProcIDWithBlock failed: \(status)") }
        procID = id
        status = AudioDeviceStart(aggregateID, id)
        guard status == noErr else { throw PrivateAggregate.Failure(description: "AudioDeviceStart failed: \(status)") }
    }

    public func stop() {
        guard let id = procID else { return }
        AudioDeviceStop(aggregateID, id)
        AudioDeviceDestroyIOProcID(aggregateID, id)
        procID = nil
    }

    // MARK: real-time

    /// Pointer + stride for a global channel index across an AudioBufferList.
    @inline(__always)
    private func channel(_ abl: UnsafeMutableAudioBufferListPointer, _ index: Int) -> (UnsafeMutablePointer<Float>, Int)? {
        var offset = 0
        for b in abl {
            let n = Int(b.mNumberChannels)
            if index < offset + n, let d = b.mData {
                return (d.assumingMemoryBound(to: Float.self) + (index - offset), n)
            }
            offset += n
        }
        return nil
    }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        guard let first = out.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }

        // 1. Append this cycle's tap input to the ring (stereo; mono is duplicated).
        let inp = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        inputLayout.store(inp.count * 1000 + (inp.first.map { Int($0.mNumberChannels) } ?? 0), ordering: .relaxed)
        var peak = Float(bitPattern: inputPeakBits.load(ordering: .relaxed))
        let l = channel(inp, 0), r = channel(inp, 1) ?? l
        for n in 0..<frames {
            var a: Float = 0, c: Float = 0
            if let (pl, sl) = l, let (pr, sr) = r, n * sl < Int(inp[0].mDataByteSize) / 4 {
                a = pl[n * sl]; c = pr[n * sr]
            }
            let w = (writePos + n) & LivePlayer.ringMask
            ringL[w] = a; ringR[w] = c
            peak = max(peak, abs(a), abs(c))
        }
        inputPeakBits.store(peak.bitPattern, ordering: .relaxed)

        // 2. Each speaker reads the ring at its own delay, with crossfade on change.
        let masterTarget: Float = muted.load(ordering: .relaxed) ? 0 : master
        let m0 = rtMaster
        for o in 0..<outCount {
            let map = outputs[o]
            guard let (chL, strideL) = channel(out, map.channelOffset) else { continue }
            let chR = map.channelCount > 1 ? channel(out, map.channelOffset + 1) : nil
            let gainTarget = Float(bitPattern: gainBits[o].load(ordering: .relaxed))
            let target = delayTarget[o].load(ordering: .relaxed)
            var cur = rtDelayCur[o], old = rtDelayOld[o], fade = rtFadePos[o], g = rtGain[o], m = m0
            let limitOn = limiter.enabled[o].load(ordering: .relaxed)
            let ceiling = Float(bitPattern: limiter.ceilingBits[o].load(ordering: .relaxed))
            for n in 0..<frames {
                if fade >= LivePlayer.delayFadeFrames && target != cur { old = cur; cur = target; fade = 0 }
                let p = writePos + n
                var a = ringL[(p - cur) & LivePlayer.ringMask]
                var c = ringR[(p - cur) & LivePlayer.ringMask]
                if fade < LivePlayer.delayFadeFrames {
                    let t = Float(fade) / Float(LivePlayer.delayFadeFrames)
                    a = a * t + ringL[(p - old) & LivePlayer.ringMask] * (1 - t)
                    c = c * t + ringR[(p - old) & LivePlayer.ringMask] * (1 - t)
                    fade += 1
                }
                g += (gainTarget - g) * smoothing
                m += (masterTarget - m) * smoothing
                let k = g * m
                a *= k
                c *= k
                if limitOn { limiter.process(output: o, &a, &c, ceiling: ceiling, state: &limiter.state[o]) }
                a = min(max(a, -1), 1)
                c = min(max(c, -1), 1)
                if let (pr, strideR) = chR {
                    chL[n * strideL] = a; pr[n * strideR] = c
                } else {
                    chL[n * strideL] = (a + c) * 0.5
                }
            }
            rtDelayCur[o] = cur; rtDelayOld[o] = old; rtFadePos[o] = fade; rtGain[o] = g
            if limitOn { limiter.publish(output: o, state: &limiter.state[o]) } else { limiter.state[o].gain = 1 }
            if o == outCount - 1 { rtMaster = m }
        }
        writePos = (writePos + frames) & LivePlayer.ringMask
        cycles.add(1, ordering: .relaxed)
    }
}
