import CoreAudio
import Foundation

/// A Core Audio process tap (macOS 14.2+): captures the audio other apps play.
/// The tapped apps' own output is muted while the tap is in use, so the music
/// is heard only through the speakers we route it to.
///
/// Requires the "System Audio Recording" privacy permission. Without it the tap
/// delivers silence rather than an error, so callers should watch the input level.
public final class SystemTap {
    public enum Target: Sendable {
        /// Every app except this process (avoids capturing our own output).
        case allApps
        /// Only the apps with these bundle IDs, e.g. "com.spotify.client" (macOS 26+).
        case apps([String])
    }

    public let id: AudioObjectID
    public let uid: String
    public let target: Target

    public init(target: Target) throws {
        let desc: CATapDescription
        switch target {
        case .allApps:
            let me = SystemTap.processObject(pid: getpid())
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me.map { [$0] } ?? [])
        case .apps(let bundleIDs):
            guard #available(macOS 26.0, *) else {
                throw PrivateAggregate.Failure(description: "tapping apps by bundle ID needs macOS 26")
            }
            desc = CATapDescription(stereoMixdownOfProcesses: [])
            desc.bundleIDs = bundleIDs
            desc.isProcessRestoreEnabled = true  // keep tapping the app across relaunches
        }
        desc.name = "SpeakerSync tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw PrivateAggregate.Failure(description: "AudioHardwareCreateProcessTap failed: \(status) '\(fourCC(UInt32(bitPattern: status)))'")
        }
        id = tapID
        uid = desc.uuid.uuidString
        self.target = target
    }

    public var format: AudioStreamBasicDescription? {
        readScalar(id, propAddr(kAudioTapPropertyFormat), AudioStreamBasicDescription())
    }

    public func destroy() {
        AudioHardwareDestroyProcessTap(id)
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = propAddr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }
}
