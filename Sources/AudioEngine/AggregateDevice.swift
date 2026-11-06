import CoreAudio
import Foundation

/// A process-private aggregate device. The first sub-device is the clock (main)
/// device; every other sub-device gets HAL drift compensation (resampling).
/// Drift compensation keeps long-term rates matched. It does NOT align the fixed
/// Bluetooth latency of each speaker; that is what the per-output delay is for.
public final class PrivateAggregate {
    public let id: AudioObjectID
    public let subDevices: [OutputDevice]

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public init(subDevices: [OutputDevice]) throws {
        guard let clock = subDevices.first else { throw Failure(description: "no sub-devices") }
        let subList: [[String: Any]] = subDevices.map {
            [kAudioSubDeviceUIDKey: $0.uid,
             kAudioSubDeviceDriftCompensationKey: $0.uid == clock.uid ? 0 : 1]
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeakerSync PoC",
            kAudioAggregateDeviceUIDKey: "local.speakersync.poc.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceSubDeviceListKey: subList,
        ]
        var newID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID)
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw Failure(description: "AudioHardwareCreateAggregateDevice failed: \(status) '\(fourCC(UInt32(bitPattern: status)))'")
        }
        id = newID
        self.subDevices = subDevices

        // The HAL builds the aggregate asynchronously; wait until it exposes every channel.
        let expected = subDevices.reduce(0) { $0 + $1.outputChannels }
        let deadline = Date().addingTimeInterval(3)
        while outputChannelCount(id) < expected && Date() < deadline {
            usleep(50_000)
        }
        let got = outputChannelCount(id)
        guard got == expected else {
            AudioHardwareDestroyAggregateDevice(id)
            throw Failure(description: "aggregate exposes \(got) output channels, expected \(expected)")
        }
    }

    public var nominalRate: Double {
        readScalar(id, propAddr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    }

    public func destroy() {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
