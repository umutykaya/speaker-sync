import AVFoundation
import AudioEngine
import CoreAudio
import Foundation
import IOKit.pwr_mgt

extension Source: @unchecked Sendable {}

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
        let kind: String  // "click" | "track"
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
        let serverTime: Date
    }

    private struct Engine {
        let aggregate: PrivateAggregate
        let player: Player
        let deviceIDs: [AudioObjectID]
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
    private var housekeeping: DispatchSourceTimer?

    init(store: Store) throws {
        self.store = store
        config = try store.loadConfig()
        tracks = store.loadTracks()
        if let id = config.currentTrackID, !tracks.contains(where: { $0.id == id }) { config.currentTrackID = nil }
        installSystemListener()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.updateSleepAssertion() } }
        timer.resume()
        housekeeping = timer
    }

    /// Keep the Mac from idle-sleeping only while audio is actually playing.
    /// Polled each second because a track can end on the audio thread.
    private func updateSleepAssertion() {
        let playing = engine.map { !$0.player.paused.load(ordering: .relaxed) } ?? false
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
        } else if loading {
            status = "loading"
        } else if lastError != nil {
            status = "error"
        } else {
            status = config.outputs.isEmpty ? "noOutputs" : "error"
        }
        let track = currentTrack
        return State(
            status: status,
            error: lastError ?? (engine == nil && !loading && !config.outputs.isEmpty ? "Outputs not active. Press Reconnect." : nil),
            notices: notices,
            positionSeconds: engine?.player.positionSeconds ?? parkedPosition,
            durationSeconds: engine?.player.durationSeconds ?? track?.durationSeconds ?? 4,
            source: track.map { SourceState(kind: "track", trackId: $0.id, name: $0.name) }
                ?? SourceState(kind: "click", trackId: nil, name: "Calibration click"),
            master: config.master,
            outputs: config.outputs.map {
                OutputState(uid: $0.uid, name: $0.name, delayMs: $0.delayMs, gain: $0.gain, matchedBy: matchKinds[$0.uid] ?? .missing)
            },
            devices: present.map {
                DeviceState(uid: $0.uid, name: $0.name, transport: $0.transportName, channels: $0.outputChannels, sampleRate: $0.nominalRate)
            },
            tracks: tracks,
            profiles: config.profiles.map { ProfileState(name: $0.name, savedAt: $0.savedAt, outputs: $0.outputs.map(\.name)) },
            sampleRate: engine?.player.sampleRate,
            serverTime: Date()
        )
    }

    // MARK: transport

    func play() throws {
        guard let p = try activePlayer() else { return }
        if p.ended.load(ordering: .relaxed) { p.seek(seconds: 0) }
        p.paused.store(false, ordering: .relaxed)
    }

    func pause() throws {
        try activePlayer()?.paused.store(true, ordering: .relaxed)
    }

    func stop() throws {
        guard let p = try activePlayer() else { return }
        p.paused.store(true, ordering: .relaxed)
        p.seek(seconds: 0)
    }

    func seek(_ seconds: Double) throws {
        guard let p = try activePlayer() else { return }
        p.seek(seconds: try Validate.seek(seconds, duration: p.durationSeconds))
    }

    private func activePlayer() throws -> Player? {
        guard let p = engine?.player else { throw APIError.conflict(lastError ?? "outputs not active") }
        return p
    }

    // MARK: levels and delays

    func setMaster(_ g: Double) throws {
        config.master = try Validate.gain(g)
        engine?.player.setMaster(Float(config.master))
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
        guard let p = engine?.player else { return }
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
        try save()
        await rebuild(position: 0)
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

        var maps: [Player.OutputMap] = []
        var offset = 0
        for d in resolved {
            maps.append(.init(channelOffset: offset, channelCount: min(d.outputChannels, 2)))
            offset += d.outputChannels
        }
        do {
            let player = try Player(aggregateID: aggregate.id, sampleRate: rate, outputs: maps, source: source)
            player.paused.store(true, ordering: .relaxed)
            if parkedPosition > 0, parkedPosition < player.durationSeconds { player.seek(seconds: parkedPosition) }
            engine = Engine(aggregate: aggregate, player: player, deviceIDs: resolved.map(\.id), listeners: [])
            applyLevels()
            installEngineListeners(gen: gen)
            try player.start()
        } catch {
            teardown()
            aggregate.destroy()
            lastError = "Could not start audio: \(error)"
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
        e.player.stop()
        for (id, addr, block) in e.listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        e.aggregate.destroy()
        engine = nil
    }

    /// Never reroute: on any loss, stop and report.
    private func deviceLost(_ what: String, gen: Int) {
        guard gen == generation, engine != nil else { return }
        generation += 1
        parkedPosition = engine?.player.positionSeconds ?? parkedPosition
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
