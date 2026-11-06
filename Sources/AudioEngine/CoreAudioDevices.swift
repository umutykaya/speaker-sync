import CoreAudio
import Foundation

// Thin helpers over the CoreAudio HAL property API (AudioObjectGetPropertyData).

public func propAddr(_ sel: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

public func readScalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = addr
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

public func readString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = propAddr(sel)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf)
    guard status == noErr, let cf else { return nil }
    return cf.takeRetainedValue() as String
}

public func readIDArray(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var a = addr
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

public func fourCC(_ v: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? String(v)
}

public struct OutputDevice {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: UInt32
    public let outputChannels: Int
    public let nominalRate: Double
    public let latencyFrames: UInt32
    public let safetyOffsetFrames: UInt32
    public let streamLatencyFrames: UInt32
    public let bufferFrames: UInt32
    public let alive: Bool

    public var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return fourCC(transport)
        }
    }

    // HAL-reported output latency. This does NOT include speaker-side Bluetooth
    // buffering or DSP, so it is informational only and never used for alignment.
    public var reportedLatencyMs: Double {
        guard nominalRate > 0 else { return 0 }
        let frames = Double(latencyFrames + safetyOffsetFrames + streamLatencyFrames + bufferFrames)
        return frames / nominalRate * 1000
    }
}

public func outputChannelCount(_ id: AudioObjectID) -> Int {
    var a = propAddr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

public func describeDevice(_ id: AudioObjectID) -> OutputDevice? {
    let channels = outputChannelCount(id)
    guard channels > 0, let uid = readString(id, kAudioDevicePropertyDeviceUID) else { return nil }
    let out = kAudioObjectPropertyScopeOutput
    let streams = readIDArray(id, propAddr(kAudioDevicePropertyStreams, out))
    let streamLatency = streams.first.flatMap { readScalar($0, propAddr(kAudioStreamPropertyLatency), UInt32(0)) } ?? 0
    return OutputDevice(
        id: id,
        uid: uid,
        name: readString(id, kAudioObjectPropertyName) ?? "?",
        transport: readScalar(id, propAddr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0,
        outputChannels: channels,
        nominalRate: readScalar(id, propAddr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0,
        latencyFrames: readScalar(id, propAddr(kAudioDevicePropertyLatency, out), UInt32(0)) ?? 0,
        safetyOffsetFrames: readScalar(id, propAddr(kAudioDevicePropertySafetyOffset, out), UInt32(0)) ?? 0,
        streamLatencyFrames: streamLatency,
        bufferFrames: readScalar(id, propAddr(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? 0,
        alive: (readScalar(id, propAddr(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) != 0
    )
}

public func allOutputDevices() -> [OutputDevice] {
    readIDArray(AudioObjectID(kAudioObjectSystemObject), propAddr(kAudioHardwarePropertyDevices))
        .compactMap(describeDevice)
}

public func printDevice(_ d: OutputDevice, indent: String = "") {
    print("\(indent)\(d.name)")
    print("\(indent)  uid=\(d.uid)")
    print(String(format: "\(indent)  transport=%@ channels=%d rate=%.0f alive=%@",
                 d.transportName, d.outputChannels, d.nominalRate, d.alive ? "yes" : "no"))
    print(String(format: "\(indent)  reported latency=%.1f ms (device %u + safety %u + stream %u + buffer %u frames)",
                 d.reportedLatencyMs, d.latencyFrames, d.safetyOffsetFrames, d.streamLatencyFrames, d.bufferFrames))
}
