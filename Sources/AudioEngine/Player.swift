import AudioToolbox
import CoreAudio
import Synchronization

/// One AUHAL output unit bound explicitly to the private aggregate device.
/// One render callback = one timeline: every speaker reads the same decoded
/// source at (playhead - its own delay). Each speaker owns a channel range of
/// the aggregate.
///
/// Real-time rules in render(): no locks, no allocation, no I/O. The control
/// thread only writes atomics; RT-only state lives in preallocated memory.
public final class Player {
    public struct OutputMap: Sendable {
        public let channelOffset: Int
        public let channelCount: Int
        public init(channelOffset: Int, channelCount: Int) {
            self.channelOffset = channelOffset
            self.channelCount = channelCount
        }
    }

    public static let maxOutputs = 2
    public static let maxFrames = 16384
    public static let delayFadeFrames = 1440  // crossfade length when a delay changes (~30 ms @ 48 kHz)

    public let source: Source
    public let sampleRate: Double
    public let outputs: [OutputMap]
    private let totalChannels: Int
    private var unit: AudioUnit?

    // Control -> RT
    public let paused = Atomic<Bool>(false)
    public let seekRequest = Atomic<Int>(-1)
    public let masterGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let delayTarget: UnsafeMutablePointer<Atomic<Int>>
    private let gainBits: UnsafeMutablePointer<Atomic<UInt32>>
    // RT -> control
    public let playhead = Atomic<Int>(0)
    public let ended = Atomic<Bool>(false)

    // RT-only state
    private let outCount: Int
    private let rtMap: UnsafeMutablePointer<OutputMap>
    private let rtDelayCur: UnsafeMutablePointer<Int>
    private let rtDelayOld: UnsafeMutablePointer<Int>
    private let rtFadePos: UnsafeMutablePointer<Int>
    private let rtGain: UnsafeMutablePointer<Float>
    private let rtMasterRamp: UnsafeMutablePointer<Float>
    private let rtPos: UnsafeMutablePointer<Int>
    private var rtMaster: Float = 0
    private var rtPlayhead = 0
    private let smoothing: Float

    public init(aggregateID: AudioObjectID, sampleRate: Double, outputs: [OutputMap], source: Source) throws {
        precondition(!outputs.isEmpty && outputs.count <= Player.maxOutputs)
        self.source = source
        self.sampleRate = sampleRate
        self.outputs = outputs
        outCount = outputs.count
        totalChannels = outputs.map { $0.channelOffset + $0.channelCount }.max()!
        smoothing = Float(1 - exp(-1 / (0.010 * sampleRate)))  // ~10 ms one-pole gain smoothing

        delayTarget = .allocate(capacity: outCount)
        gainBits = .allocate(capacity: outCount)
        rtMap = .allocate(capacity: outCount)
        rtDelayCur = .allocate(capacity: outCount)
        rtDelayOld = .allocate(capacity: outCount)
        rtFadePos = .allocate(capacity: outCount)
        rtGain = .allocate(capacity: outCount)
        for i in 0..<outCount {
            (delayTarget + i).initialize(to: Atomic(0))
            (gainBits + i).initialize(to: Atomic(Float(1).bitPattern))
            rtMap[i] = outputs[i]
            rtDelayCur[i] = 0
            rtDelayOld[i] = 0
            rtFadePos[i] = Player.delayFadeFrames
            rtGain[i] = 1
        }
        rtMasterRamp = .allocate(capacity: Player.maxFrames)
        rtPos = .allocate(capacity: Player.maxFrames)

        try setUpUnit(aggregateID: aggregateID)
    }

    // MARK: control API (any non-RT thread)

    public func setDelay(output: Int, ms: Double) {
        delayTarget[output].store(Int((ms / 1000 * sampleRate).rounded()), ordering: .relaxed)
    }
    public func delayMs(output: Int) -> Double {
        Double(delayTarget[output].load(ordering: .relaxed)) / sampleRate * 1000
    }
    public func setGain(output: Int, _ g: Float) {
        gainBits[output].store(min(max(g, 0), 1).bitPattern, ordering: .relaxed)
    }
    public func gain(output: Int) -> Float { Float(bitPattern: gainBits[output].load(ordering: .relaxed)) }
    public func setMaster(_ g: Float) { masterGainBits.store(min(max(g, 0), 1).bitPattern, ordering: .relaxed) }
    public var master: Float { Float(bitPattern: masterGainBits.load(ordering: .relaxed)) }
    public func seek(seconds: Double) {
        ended.store(false, ordering: .relaxed)
        seekRequest.store(max(0, Int(seconds * sampleRate)), ordering: .relaxed)
    }
    /// A pending seek is reported as the position, so callers never see the
    /// pre-seek value in the few ms before the render thread applies it.
    public var positionSeconds: Double {
        let pending = seekRequest.load(ordering: .relaxed)
        let p = pending >= 0 ? pending : playhead.load(ordering: .relaxed)
        return Double(source.loops ? p % source.frames : min(p, source.frames)) / sampleRate
    }
    public var durationSeconds: Double { Double(source.frames) / sampleRate }

    public func start() throws { try check(AudioOutputUnitStart(unit!), "AudioOutputUnitStart") }

    public func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    // MARK: setup

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw PrivateAggregate.Failure(description: "\(what) failed: \(s)") }
    }

    private func setUpUnit(aggregateID: AudioObjectID) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw PrivateAggregate.Failure(description: "HALOutput component not found")
        }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "AudioComponentInstanceNew")
        guard let u else { throw PrivateAggregate.Failure(description: "no AudioUnit") }
        unit = u

        var off: UInt32 = 0, on: UInt32 = 1
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, 4), "disable input")
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, 4), "enable output")
        // Bind to the aggregate explicitly. Never the default device, so audio cannot
        // silently move to the Mac's internal speaker.
        var dev = aggregateID
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioObjectID>.size)), "set CurrentDevice")

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(totalChannels), mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set stream format")
        var maxFrames = UInt32(Player.maxFrames)
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &maxFrames, 4), "set MaximumFramesPerSlice")

        var cb = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData in
            Unmanaged<Player>.fromOpaque(refCon).takeUnretainedValue().render(frames: Int(frames), ioData: ioData!)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render callback")
        try check(AudioUnitInitialize(u), "AudioUnitInitialize")
    }

    // MARK: real-time render

    @inline(__always)
    private func sample(_ buf: UnsafeMutablePointer<Float>, _ idx: Int) -> Float {
        let n = source.frames
        if source.loops {
            if idx < 0 { return 0 }
            return buf[idx % n]
        }
        return (idx >= 0 && idx < n) ? buf[idx] : 0
    }

    private func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        guard frames <= Player.maxFrames else { return }

        // 1. Transport: master gain ramp and playhead per frame (shared by all outputs).
        let isPaused = paused.load(ordering: .relaxed)
        let seekTo = seekRequest.load(ordering: .relaxed)
        let masterTarget: Float = (isPaused || seekTo >= 0) ? 0 : master
        var maxDelay = 0
        for o in 0..<outCount { maxDelay = max(maxDelay, max(rtDelayCur[o], delayTarget[o].load(ordering: .relaxed))) }
        for f in 0..<frames {
            rtMaster += (masterTarget - rtMaster) * smoothing
            rtMasterRamp[f] = rtMaster
            rtPos[f] = rtPlayhead
            let silent = rtMaster < 1e-4
            if seekTo >= 0 && silent {
                // Jump only once faded out, to avoid a click.
                if seekRequest.compareExchange(expected: seekTo, desired: -1, ordering: .relaxed).exchanged {
                    rtPlayhead = seekTo
                }
            } else if !(isPaused && silent) {
                rtPlayhead += 1
            }
        }
        if !source.loops && rtPlayhead >= source.frames + maxDelay && !isPaused {
            paused.store(true, ordering: .relaxed)
            ended.store(true, ordering: .relaxed)
        }
        playhead.store(rtPlayhead, ordering: .relaxed)

        // 2. Per output: delayed read, delay-change crossfade, gain, write channels.
        for o in 0..<outCount {
            let map = rtMap[o]
            guard map.channelOffset + map.channelCount <= abl.count,
                  let chL = abl[map.channelOffset].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let chR = map.channelCount > 1 ? abl[map.channelOffset + 1].mData?.assumingMemoryBound(to: Float.self) : nil
            let gainTarget = Float(bitPattern: gainBits[o].load(ordering: .relaxed))
            let target = delayTarget[o].load(ordering: .relaxed)
            var cur = rtDelayCur[o], old = rtDelayOld[o], fade = rtFadePos[o], g = rtGain[o]
            for f in 0..<frames {
                if fade >= Player.delayFadeFrames && target != cur {
                    old = cur; cur = target; fade = 0
                }
                let p = rtPos[f]
                var l = sample(source.left, p - cur)
                var r = sample(source.right, p - cur)
                if fade < Player.delayFadeFrames {
                    let t = Float(fade) / Float(Player.delayFadeFrames)
                    l = l * t + sample(source.left, p - old) * (1 - t)
                    r = r * t + sample(source.right, p - old) * (1 - t)
                    fade += 1
                }
                g += (gainTarget - g) * smoothing
                let k = g * rtMasterRamp[f]
                // Gains are capped at 1.0; the hard clamp is a last-resort safety net.
                l = min(max(l * k, -1), 1)
                r = min(max(r * k, -1), 1)
                if let chR {
                    chL[f] = l; chR[f] = r
                } else {
                    chL[f] = (l + r) * 0.5
                }
            }
            rtDelayCur[o] = cur; rtDelayOld[o] = old; rtFadePos[o] = fade; rtGain[o] = g
        }
    }
}
