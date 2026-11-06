import AudioEngine
import CoreAudio
import Foundation

/// `ssync-poc live`: route system audio (all apps, or chosen apps) to the speakers.
func runLive(_ args: [String]) -> Never {
    var outUIDs: [String] = []
    var apps: [String] = []
    var delays = [0.0, 0.0]
    var master: Float = 1
    var i = 0
    func next() -> String {
        i += 1
        guard i < args.count else { usage() }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--out": outUIDs.append(next())
        case "--app": apps.append(next())
        case "--delay1": delays[0] = Double(next()) ?? -1
        case "--delay2": delays[1] = Double(next()) ?? -1
        case "--master": master = Float(next()) ?? -1
        default: usage()
        }
        i += 1
    }
    guard (1...LivePlayer.maxOutputs).contains(outUIDs.count), Set(outUIDs).count == outUIDs.count else {
        fail("pass one or two distinct --out UIDs (see `ssync-poc list`)")
    }
    guard delays.allSatisfy({ (0...2000).contains($0) }), (0...1).contains(master) else { fail("delays 0...2000 ms, master 0...1") }

    let devices = allOutputDevices()
    let chosen: [OutputDevice] = outUIDs.map { uid in
        guard let d = devices.first(where: { $0.uid == uid }) else { fail("no output device with uid \(uid)") }
        return d
    }

    let tap: SystemTap
    do { tap = try SystemTap(target: apps.isEmpty ? .allApps : .apps(apps)) } catch { fail("\(error)") }
    if let f = tap.format {
        print(String(format: "tap: %@, %.0f Hz, %u ch, format '%@' flags 0x%x",
                     apps.isEmpty ? "all apps except this one" : apps.joined(separator: ", "),
                     f.mSampleRate, f.mChannelsPerFrame, fourCC(f.mFormatID), f.mFormatFlags))
    }

    let aggregate: PrivateAggregate
    do { aggregate = try PrivateAggregate(subDevices: chosen, tapUID: tap.uid) } catch { tap.destroy(); fail("\(error)") }
    let rate = aggregate.nominalRate
    print(String(format: "aggregate id=%u rate=%.0f out channels=%d", aggregate.id, rate, outputChannelCount(aggregate.id)))

    var maps: [Player.OutputMap] = []
    var offset = 0
    for d in chosen {
        maps.append(.init(channelOffset: offset, channelCount: min(d.outputChannels, 2)))
        offset += d.outputChannels
    }
    let live = LivePlayer(aggregateID: aggregate.id, sampleRate: rate, outputs: maps)
    for n in 0..<maps.count { live.setDelay(output: n, ms: delays[n]) }
    live.setMaster(master)

    func shutdown(_ code: Int32, _ reason: String) -> Never {
        print(reason)
        live.stop()
        aggregate.destroy()
        tap.destroy()
        exit(code)
    }

    var devicesAddr = propAddr(kAudioHardwarePropertyDevices)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, .main) { _, _ in
        let present = Set(allOutputDevices().map(\.uid))
        let missing = chosen.filter { !present.contains($0.uid) }.map(\.name)
        if !missing.isEmpty { shutdown(3, "DEVICE LOST: \(missing.joined(separator: ", ")) — stopped") }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { shutdown(0, "interrupted") }
    sigint.resume()

    func status() -> String {
        let peak = live.takeInputPeak()
        let db = peak > 0 ? String(format: "%.0f dBFS", 20 * log10(peak)) : "silent"
        var s = "input peak \(db)\(live.muted.load(ordering: .relaxed) ? " | MUTED" : "")"
        for n in 0..<maps.count {
            s += String(format: " | out%d %@ delay=%.1fms gain=%.2f", n + 1, chosen[n].name, live.delayMs(output: n), live.gain(output: n))
        }
        let layout = live.inputLayout.load(ordering: .relaxed)
        return s + String(format: " | master=%.2f cycles=%d input=%d buf x %d ch", live.master,
                          live.cycles.load(ordering: .relaxed), layout / 1000, layout % 1000)
    }

    let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    stdinSource.setEventHandler {
        guard let line = readLine() else { stdinSource.cancel(); return }
        let parts = line.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return }
        func idx(_ s: String) -> Int? { Int(s).flatMap { (1...maps.count).contains($0) ? $0 - 1 : nil } }
        switch cmd {
        case "q": shutdown(0, "bye")
        case "p": live.muted.store(!live.muted.load(ordering: .relaxed), ordering: .relaxed)
        case "m" where parts.count == 2:
            guard let g = Float(parts[1]), (0...1).contains(g) else { print("master 0...1"); return }
            live.setMaster(g)
        case "g" where parts.count == 3:
            guard let n = idx(parts[1]), let g = Float(parts[2]), (0...1).contains(g) else { print("gain 0...1"); return }
            live.setGain(output: n, g)
        case "d" where parts.count == 3:
            guard let n = idx(parts[1]), let v = Double(parts[2]) else { print("bad delay"); return }
            let ms = (parts[2].hasPrefix("+") || parts[2].hasPrefix("-")) ? live.delayMs(output: n) + v : v
            guard (0...2000).contains(ms) else { print("delay must stay within 0...2000 ms"); return }
            live.setDelay(output: n, ms: ms)
        default: print("commands: d <n> <ms|+ms|-ms>, g <n> <0..1>, m <0..1>, p (mute), q"); return
        }
        print(status())
    }
    stdinSource.resume()

    let ticker = DispatchSource.makeTimerSource(queue: .main)
    ticker.schedule(deadline: .now() + 5, repeating: 5)
    ticker.setEventHandler { print(status()) }
    ticker.resume()

    do { try live.start() } catch { shutdown(1, "\(error)") }
    print("live. Play something on the Mac (e.g. Spotify). Commands: d, g, m, p (mute), q")
    dispatchMain()
}
