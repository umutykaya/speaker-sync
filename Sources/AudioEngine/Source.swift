import AVFoundation

/// Decoded stereo Float32 audio, fully in memory at the output sample rate.
/// Decoding happens once, off the real-time thread, before playback starts.
public final class Source {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    public let frames: Int
    public let loops: Bool
    private let storage: AVAudioPCMBuffer

    private init(buffer: AVAudioPCMBuffer, loops: Bool) {
        storage = buffer
        left = buffer.floatChannelData![0]
        right = buffer.floatChannelData![buffer.format.channelCount > 1 ? 1 : 0]
        frames = Int(buffer.frameLength)
        self.loops = loops
    }

    public struct Failure: Error, CustomStringConvertible { public let description: String }

    public static func load(url: URL, sampleRate: Double) throws -> Source {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure(description: "cannot allocate decode buffer")
        }
        try file.read(into: inBuf)

        let outChannels: AVAudioChannelCount = inFormat.channelCount >= 2 ? 2 : 1
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: outChannels, interleaved: false)!
        if inFormat == outFormat { return Source(buffer: inBuf, loops: false) }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw Failure(description: "no converter \(inFormat) -> \(outFormat)")
        }
        converter.downmix = inFormat.channelCount > 2
        let ratio = sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw Failure(description: "cannot allocate output buffer")
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return inBuf
        }
        if status == .error { throw Failure(description: "conversion failed: \(error?.localizedDescription ?? "?")") }
        return Source(buffer: outBuf, loops: false)
    }

    /// Calibration click track: one short decaying tone burst per second, peak -6 dBFS.
    /// Every 4th click is higher pitched, so a misalignment of a whole beat is audible.
    public static func clickTrack(sampleRate: Double) -> Source {
        let beats = 4
        let beatFrames = Int(sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(beats * beatFrames))!
        buf.frameLength = buf.frameCapacity
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        for i in 0..<Int(buf.frameLength) { l[i] = 0; r[i] = 0 }
        let burst = Int(0.03 * sampleRate)
        for beat in 0..<beats {
            let accent = beat == 0
            let freq = accent ? 2000.0 : 1200.0
            // Equal level for every beat: the Go 4 seemed to play only the louder accent beats.
            let amp: Float = 0.5
            for n in 0..<burst {
                let t = Double(n) / sampleRate
                let v = amp * Float(exp(-t / 0.004) * sin(2 * .pi * freq * t))
                l[beat * beatFrames + n] = v
                r[beat * beatFrames + n] = v
            }
        }
        return Source(buffer: buf, loops: true)
    }
}
