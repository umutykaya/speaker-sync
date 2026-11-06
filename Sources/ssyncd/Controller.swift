import AVFoundation
import AudioEngine
import CoreAudio
import Foundation
import IOKit.pwr_mgt

extension Source: @unchecked Sendable {}

/// What the controller needs from either renderer.
protocol OutputEngine: AnyObject {
    var outputs: [Player.OutputMap] { get }
    var sampleRate: Double { get }
    func setDelay(output: Int, ms: Double)
    func setGain(output: Int, _ g: Float)
    func setMaster(_ g: Float)
    func start() throws
    func stop()
}
extension Player: OutputEngine {}
extension LivePlayer: OutputEngine {}

/// Authoritative playback state. All mutation happens on the main actor; the
/// audio thread only sees the Player's atomics. Browsers never hold state: they
/// read a fresh `State` snapshot after every call and on every poll.
@MainActor
final class Controller {
    struct OutputState: Codable, Sendable {
        let uid: String
        let name: String
        let delayMs: Double
        let gain: Double
        let matchedBy: MatchKind
    }
    struct DeviceState: Codable, Sendable {
        let uid: String
        let name: String
        let transport: String
        let channels: Int
        let sampleRate: Double
    }
    struct SourceState: Codable, Sendable {
        let kind: String  // "click" | "track" | "live"
        let trackId: String?
        let name: String
    }
    struct ProfileState: Codable, Sendable {
        let name: String
        let savedAt: Date
        let outputs: [String]
    }
    struct State: Codable, Sendable {
        /// noOutputs | loading | playing | paused | ended | error
        let status: String
        let error: String?
        let notices: [String]
        let positionSeconds: Double
        let durationSeconds: Double
        let source: SourceState
        let master: Double
        let outputs: [OutputState]
        let devices: [DeviceState]
        let tracks: [Track]
        let profiles: [ProfileState]
        let sampleRate: Double?
        /// Live source only: peak input over the last second (nil when silent or not live).
        let inputLevelDb: Double?
        /// Live source only: seconds since audio was last received; -1 if none yet.
        let liveSilentSeconds: Double?
        let serverTime: Date
    }

    private struct Engine {
        let aggregate: PrivateAggregate
        let output: any OutputEngine
        let tap: SystemTap?
        let deviceIDs: [AudioObjectID]
        var player: Player? { output as? Player }
        var live: LivePlayer? { output as? LivePlayer }
        var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]
    }

    private let store: Store
    private(set) var config: Config
    private var tracks: [Track]
    private var engine: Engine?
    private var generation = 0
    private var loading = false
    private var lastError: String?
    private var notices: [String] = []
    private var matchKinds: [String: MatchKind] = [:]
    /// Position kept while no engine exists (device lost, rebuilding).
    private var parkedPosition = 0.0
    private var cachedSource: (key: String, source: Source)?
    private var sleepAssertion: IOPMAssertionID = 0
    private var lastInputPeak: Float = 0
    private var lastAudioAt: Date?
    private var housekeeping: DispatchSourceTimer?

    init(store: Store) throws {
        self.store = store
        config = try store.loadConfig()
        tracks = store.loadTracks()
        if let id = config.currentTrackID, !tracks.contains(where: { $0.id == id }) { config.currentTrackID = nil }
        installSystemListener()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        housekeeping = timer
    }

    private func tick() {
        if let live = engine?.live {
            lastInputPeak = live.takeInputPeak()
            if lastInputPeak > 0.001 { lastAudioAt = Date() }
        }
        updateSleepAssertion()
    }

    /// Keep the Mac from idle-sleeping only while audio is actually playing:
    /// a file that is not paused, or an unmuted live source that received audio
    /// in the last minute. Polled each second because a track can end on the
    /// audio thread.
    private func updateSleepAssertion() {
        let playing: Bool
        if let p = engine?.player {
            playing = !p.paused.load(ordering: .relaxed)
        } else if let l = engine?.live {
            playing = !l.muted.load(ordering: .relaxed) && (lastAudioAt.map { Date().timeIntervalSince($0) < 60 } ?? false)
        } else {
            playing = false
        }
        if playing && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Speaker Sync is playing" as CFString, &sleepAssertion)
        } else if !playing && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: snapshot

    func state() -> State {
        let present = presentDevices()
        let status: String
        if let p = engine?.player {
            status = p.ended.load(ordering: .relaxed) ? "ended" : (p.paused.load(ordering: .relaxed) ? "paused" : "playing")
        } else if let l = engine?.live {
            status = l.muted.load(ordering: .relaxed) ? "paused" : "playing"
        } else if loading {
            status = "loading"
        } else if lastError != nil {
            status = "error"
        } else {
            status = config.outputs.isEmpty ? "noOutputs" : "error"
        }
        let track = currentTrack
        let isLive = config.liveTarget != nil
        let source: SourceState
        if let target = config.liveTarget {
            source = SourceState(kind: "live", trackId: nil, name: Controller.liveName(target))
        } else if let track {
            source = SourceState(kind: "track", trackId: track.id, name: track.name)
        } else {
            source = SourceState(kind: "click", trackId: nil, name: "Calibration click")
        }
        let live = engine?.live
        return State(
            status: status,
            error: lastError ?? (engine == nil && !loading && !config.outputs.isEmpty ? "Outputs not active. Press Reconnect." : nil),
            notices: notices,
            positionSeconds: isLive ? 0 : (engine?.player?.positionSeconds ?? parkedPosition),
            durationSeconds: isLive ? 0 : (engine?.player?.durationSeconds ?? track?.durationSeconds ?? 4),
            source: source,
            master: config.master,
            outputs: config.outputs.map {
                OutputState(uid: $0.uid, name: $0.name, delayMs: $0.delayMs, gain: $0.gain, matchedBy: matchKinds[$0.uid] ?? .missing)
            },
            devices: present.map {
                DeviceState(uid: $0.uid, name: $0.name, transport: $0.transportName, channels: $0.outputChannels, sampleRate: $0.nominalRate)
            },
            tracks: tracks,
            profiles: config.profiles.map { ProfileState(name: $0.name, savedAt: $0.savedAt, outputs: $0.outputs.map(\.name)) },
            sampleRate: engine?.output.sampleRate,
            inputLevelDb: live != nil && lastInputPeak > 0 ? Double(20 * log10(lastInputPeak)) : nil,
            liveSilentSeconds: live == nil ? nil : lastAudioAt.map { Date().timeIntervalSince($0) } ?? -1,
            serverTime: Date()
        )
    }

    // MARK: transport

    // For the live source, play/pause/stop unmute/mute the speakers. The app
    // producing the audio (e.g. Spotify) keeps its own transport.
    func play() throws {
        let e = try activeEngine()
        if let l = e.live { l.muted.store(false, ordering: .relaxed); return }
        guard let p = e.player else { return }
        if p.ended.load(ordering: .relaxed) { p.seek(seconds: 0) }
        p.paused.store(false, ordering: .relaxed)
    }

    func pause() throws {
        let e = try activeEngine()
        e.live?.muted.store(true, ordering: .relaxed)
        e.player?.paused.store(true, ordering: .relaxed)
    }

    func stop() throws {
        let e = try activeEngine()
        e.live?.muted.store(true, ordering: .relaxed)
        if let p = e.player {
            p.paused.store(true, ordering: .relaxed)
            p.seek(seconds: 0)
        }
    }

    func seek(_ seconds: Double) throws {
        guard let p = try activeEngine().player else { throw APIError.conflict("seek is not available for live audio") }
        p.seek(seconds: try Validate.seek(seconds, duration: p.durationSeconds))
    }

    private func activeEngine() throws -> Engine {
        guard let e = engine else { throw APIError.conflict(lastError ?? "outputs not active") }
        return e
    }

    // MARK: levels and delays

    func setMaster(_ g: Double) throws {
        config.master = try Validate.gain(g)
        engine?.output.setMaster(Float(config.master))
        try save()
    }

    func setOutput(uid: String, delayMs: Double?, gain: Double?) throws {
        guard let i = config.outputs.firstIndex(where: { $0.uid == uid }) else { throw APIError.notFound("output not selected: \(uid)") }
        if let d = delayMs { config.outputs[i].delayMs = try Validate.delayMs(d) }
        if let g = gain { config.outputs[i].gain = try Validate.gain(g) }
        applyLevels()
        try save()
    }

    private func applyLevels() {
        guard let p = engine?.output else { return }
        p.setMaster(Float(config.master))
        for (i, o) in config.outputs.enumerated() where i < p.outputs.count {
            p.setDelay(output: i, ms: o.delayMs)
            p.setGain(output: i, Float(o.gain))
        }
    }

    // MARK: selection, source, reconnect

    func selectOutputs(_ uids: [String]) async throws {
        let present = presentDevices()
        let valid = try Validate.outputUIDs(uids, present: Set(present.map(\.uid)))
        let known = config.outputs + config.profiles.flatMap(\.outputs)
        config.outputs = valid.map { uid in
            let name = present.first { $0.uid == uid }!.name
            let prior = known.first { $0.uid == uid }
            return SavedOutput(uid: uid, name: name, delayMs: prior?.delayMs ?? 0, gain: prior?.gain ?? 1)
        }
        try save()
        await rebuild(position: 0)
    }

    func setSource(trackID: String?) async throws {
        if let id = trackID, !tracks.contains(where: { $0.id == id }) { throw APIError.notFound("no track \(id)") }
        config.currentTrackID = trackID
        config.liveTarget = nil
        try save()
        await rebuild(position: 0)
    }

    /// Live audio from this Mac: "all" apps, or one app by bundle ID.
    func setLiveSource(_ target: String) async throws {
        config.liveTarget = try Validate.liveTarget(target)
        try save()
        await rebuild(position: 0)
    }

    static func liveName(_ target: String) -> String {
        switch target {
        case "all": return "All Mac audio"
        case "com.spotify.client": return "Spotify"
        default: return target
        }
    }

    func reconnect() async {
        await rebuild()
    }

    /// Tear down and rebuild the aggregate + player. Always lands paused, at
    /// `position` or else the previous position. Safe to call while another
    /// rebuild is in flight: the older one notices the generation change and
    /// abandons its result.
    func rebuild(position: Double? = nil) async {
        generation += 1
        let gen = generation
        if let position { parkedPosition = position } else if let p = engine?.player { parkedPosition = p.positionSeconds }
        lastInputPeak = 0
        lastAudioAt = nil
        teardown()
        lastError = nil
        notices = []
        matchKinds = [:]
        guard !config.outputs.isEmpty else { return }

        // Resolve saved outputs: UID first, unique display name as fallback.
        let present = presentDevices()
        let matches = matchOutputs(config.outputs, present: present.map { PresentDevice(uid: $0.uid, name: $0.name) })
        var resolved: [OutputDevice] = []
        for m in matches {
            guard let uid = m.uid, let dev = present.first(where: { $0.uid == uid }) else {
                matchKinds[m.saved.uid] = .missing
                lastError = "\(m.saved.name) is not connected. Connect it in Bluetooth settings, then press Reconnect."
                return
            }
            if m.kind == .name {
                notices.append("\(dev.name) found by name; its device ID changed and was updated.")
                if let i = config.outputs.firstIndex(where: { $0.uid == m.saved.uid }) { config.outputs[i].uid = uid }
            }
            matchKinds[uid] = m.kind
            resolved.append(dev)
        }
        try? save()

        loading = true
        defer { if gen == generation { loading = false } }
        var maps: [Player.OutputMap] = []
        var offset = 0
        for d in resolved {
            maps.append(.init(channelOffset: offset, channelCount: min(d.outputChannels, 2)))
            offset += d.outputChannels
        }
        if let target = config.liveTarget {
            await startLive(target: target, devices: resolved, maps: maps, gen: gen)
            return
        }
        let aggregate: PrivateAggregate
        do { aggregate = try PrivateAggregate(subDevices: resolved) } catch {
            lastError = "Could not open outputs: \(error)"
            return
        }
        let rate = aggregate.nominalRate
        let source: Source
        do { source = try await loadSource(rate: rate) } catch {
            aggregate.destroy()
            if gen == generation { lastError = "Could not decode audio: \(error)" }
            return
        }
        guard gen == generation else { aggregate.destroy(); return }

        do {
            let player = try Player(aggregateID: aggregate.id, sampleRate: rate, outputs: maps, source: source)
            player.paused.store(true, ordering: .relaxed)
            if parkedPosition > 0, parkedPosition < player.durationSeconds { player.seek(seconds: parkedPosition) }
            engine = Engine(aggregate: aggregate, output: player, tap: nil, deviceIDs: resolved.map(\.id), listeners: [])
            applyLevels()
            installEngineListeners(gen: gen)
            try player.start()
        } catch {
            if engine == nil { aggregate.destroy() }
            teardown()
            lastError = "Could not start audio: \(error)"
        }
    }

    /// Live source: process tap -> aggregate input; speakers -> aggregate outputs.
    /// Lands muted, like the file player lands paused.
    private func startLive(target: String, devices: [OutputDevice], maps: [Player.OutputMap], gen: Int) async {
        // Creating a bundle-ID tap right after tearing down the previous engine
        // can fail without an error code while the HAL finishes the (asynchronous)
        // aggregate destruction, so retry for up to ~2 s.
        var made: SystemTap?
        var lastFailure: Error?
        for attempt in 0..<20 {
            do { made = try SystemTap(target: target == "all" ? .allApps : .apps([target])); break } catch {
                lastFailure = error
                if attempt < 19 { try? await Task.sleep(for: .milliseconds(100)) }
                guard gen == generation else { return }
            }
        }
        guard let tap = made else {
            lastError = "Could not capture audio from \(Controller.liveName(target)). Is it running on this Mac? (\(lastFailure.map { "\($0)" } ?? "unknown error"))"
            return
        }
        guard gen == generation else { tap.destroy(); return }
        let aggregate: PrivateAggregate
        do { aggregate = try PrivateAggregate(subDevices: devices, tapUID: tap.uid) } catch {
            tap.destroy()
            lastError = "Could not open outputs: \(error)"
            return
        }
        let live = LivePlayer(aggregateID: aggregate.id, sampleRate: aggregate.nominalRate, outputs: maps)
        live.muted.store(true, ordering: .relaxed)
        engine = Engine(aggregate: aggregate, output: live, tap: tap, deviceIDs: devices.map(\.id), listeners: [])
        applyLevels()
        installEngineListeners(gen: gen)
        do { try live.start() } catch {
            teardown()
            lastError = "Could not start live audio: \(error)"
        }
    }

    private func loadSource(rate: Double) async throws -> Source {
        let track = currentTrack
        let key = "\(track?.id ?? "click")@\(rate)"
        if let c = cachedSource, c.key == key { return c.source }
        let url = track.map(store.trackURL)
        let source = try await Task.detached(priority: .userInitiated) {
            try url.map { try Source.load(url: $0, sampleRate: rate) } ?? Source.clickTrack(sampleRate: rate)
        }.value
        cachedSource = (key, source)  // one slot: a whole decoded file can be large
        return source
    }

    private func teardown() {
        guard let e = engine else { return }
        e.output.stop()
        for (id, addr, block) in e.listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        e.aggregate.destroy()
        e.tap?.destroy()
        engine = nil
    }

    /// Never reroute: on any loss, stop and report.
    private func deviceLost(_ what: String, gen: Int) {
        guard gen == generation, engine != nil else { return }
        generation += 1
        parkedPosition = engine?.player?.positionSeconds ?? parkedPosition
        teardown()
        lastError = "\(what). Playback stopped. Reconnect the speaker, then press Reconnect."
        print("[ssyncd] \(lastError!)")
    }

    private func installEngineListeners(gen: Int) {
        guard var e = engine else { return }
        let names = Dictionary(uniqueKeysWithValues: zip(e.deviceIDs, config.outputs.map(\.name)))
        for id in [e.aggregate.id] + e.deviceIDs {
            let addr = propAddr(kAudioDevicePropertyDeviceIsAlive)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    if (readScalar(id, propAddr(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) == 0 {
                        self?.deviceLost("\(names[id] ?? "Audio device") disconnected", gen: gen)
                    }
                }
            }
            var a = addr
            if AudioObjectAddPropertyListenerBlock(id, &a, .main, block) == noErr { e.listeners.append((id, addr, block)) }
        }
        let rateAddr = propAddr(kAudioDevicePropertyNominalSampleRate)
        let aggID = e.aggregate.id
        let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                let r = readScalar(aggID, propAddr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
                self?.deviceLost(String(format: "Output sample rate changed to %.0f Hz", r), gen: gen)
            }
        }
        var ra = rateAddr
        if AudioObjectAddPropertyListenerBlock(aggID, &ra, .main, rateBlock) == noErr { e.listeners.append((aggID, rateAddr, rateBlock)) }
        engine = e
    }

    /// Device-list changes: catch a selected speaker vanishing even if its
    /// "alive" notification never arrives.
    private func installSystemListener() {
        var addr = propAddr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.engine != nil else { return }
                let present = Set(self.presentDevices().map(\.uid))
                if let gone = self.config.outputs.first(where: { !present.contains($0.uid) }) {
                    self.deviceLost("\(gone.name) disconnected", gen: self.generation)
                }
            }
        }
    }

    // MARK: tracks

    private var currentTrack: Track? { config.currentTrackID.flatMap { id in tracks.first { $0.id == id } } }

    var libraryBytes: Int { tracks.reduce(0) { $0 + $1.bytes } }

    /// Takes ownership of a fully written temp file inside the library directory.
    func addTrack(tempFile: URL, name: String, ext: String, bytes: Int) async throws -> Track {
        let duration: Double
        do {
            duration = try await Task.detached {
                let f = try AVAudioFile(forReading: tempFile)
                return Double(f.length) / f.processingFormat.sampleRate
            }.value
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            throw APIError(status: 415, message: "not a readable audio file")
        }
        guard duration > 0, duration < 4 * 3600 else {
            try? FileManager.default.removeItem(at: tempFile)
            throw APIError(status: 415, message: "audio duration out of range")
        }
        let id = UUID().uuidString.lowercased()
        let track = Track(id: id, name: name, fileName: "\(id).\(ext)", bytes: bytes, durationSeconds: duration, addedAt: Date())
        try FileManager.default.moveItem(at: tempFile, to: store.trackURL(track))
        tracks.append(track)
        try store.saveTracks(tracks)
        return track
    }

    func deleteTrack(_ id: String) async throws {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw APIError.notFound("no track \(id)") }
        let t = tracks.remove(at: i)
        try store.saveTracks(tracks)
        try? FileManager.default.removeItem(at: store.trackURL(t))
        if config.currentTrackID == id { try await setSource(trackID: nil) }
    }

    // MARK: profiles

    func saveProfile(_ rawName: String) throws {
        let name = try Validate.profileName(rawName)
        guard !config.outputs.isEmpty else { throw APIError.conflict("select outputs first") }
        let p = Profile(name: name, outputs: config.outputs, master: config.master, savedAt: Date())
        config.profiles.removeAll { $0.name == name }
        config.profiles.append(p)
        try save()
    }

    /// Applies a profile's speakers and calibration. Its devices are matched by
    /// UID, then by unique name, so a changed UID does not break the profile.
    func loadProfile(_ name: String) async throws {
        guard let p = config.profiles.first(where: { $0.name == name }) else { throw APIError.notFound("no profile \(name)") }
        config.outputs = p.outputs
        config.master = p.master
        try save()
        await rebuild()
    }

    func deleteProfile(_ name: String) throws {
        guard config.profiles.contains(where: { $0.name == name }) else { throw APIError.notFound("no profile \(name)") }
        config.profiles.removeAll { $0.name == name }
        try save()
    }

    // MARK: helpers

    func presentDevices() -> [OutputDevice] {
        allOutputDevices().filter { $0.transport != kAudioDeviceTransportTypeAggregate }
    }

    private func save() throws {
        do { try store.saveConfig(config) } catch { throw APIError(status: 500, message: "could not save settings: \(error)") }
    }
}
