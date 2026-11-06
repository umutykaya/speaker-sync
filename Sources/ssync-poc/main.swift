import AudioEngine
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func usage() -> Never {
    print("""
    usage:
      ssync-poc list
      ssync-poc play --out <UID> [--out <UID>] (--file <path> | --click) [--delay1 ms] [--delay2 ms] [--master 0..1]
      ssync-poc live --out <UID> [--out <UID>] [--app <bundle id>]... [--delay1 ms] [--delay2 ms] [--master 0..1]
                     route system audio (all apps, or only --app ones, e.g. com.spotify.client)

    The first --out is the aggregate clock device; the second gets drift compensation.
    Interactive commands while playing (output index is 1 or 2):
      d <n> <ms>     set delay of output n (0...2000 ms)
      d <n> +<ms>    nudge delay up (e.g. d 2 +5), d <n> -<ms> nudge down
      g <n> <0..1>   output gain        m <0..1>   master gain
      p              pause/resume       s <sec>    seek
      i              device info        q          quit
    """)
    exit(2)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

if command == "list" {
    let devices = allOutputDevices()
    if devices.isEmpty { print("no output devices") }
    for d in devices { printDevice(d); print("") }
    exit(0)
}
if command == "live" { runLive(args) }
guard command == "play" else { usage() }

var outUIDs: [String] = []
var filePath: String?
var click = false
var initialDelays = [0.0, 0.0]
var initialMaster: Float = 1
var i = 0
func nextArg() -> String {
    i += 1
    guard i < args.count else { usage() }
    return args[i]
}
while i < args.count {
    switch args[i] {
    case "--out": outUIDs.append(nextArg())
    case "--file": filePath = nextArg()
    case "--click": click = true
    case "--delay1": initialDelays[0] = Double(nextArg()) ?? -1
    case "--delay2": initialDelays[1] = Double(nextArg()) ?? -1
    case "--master": initialMaster = Float(nextArg()) ?? -1
    default: usage()
    }
    i += 1
}
guard (1...2).contains(outUIDs.count), Set(outUIDs).count == outUIDs.count else {
    fail("pass one or two distinct --out UIDs (see `ssync-poc list`)")
}
guard click != (filePath != nil) else { fail("pass exactly one of --file or --click") }
guard (0...1).contains(initialMaster) else { fail("master must be 0...1") }
guard initialDelays.allSatisfy({ (0...2000).contains($0) }) else { fail("delays must be 0...2000 ms") }

// Resolve by stable UID, never by display name.
let devices = allOutputDevices()
let chosen: [OutputDevice] = outUIDs.map { uid in
    guard let d = devices.first(where: { $0.uid == uid }) else { fail("no output device with uid \(uid)") }
    return d
}
print("sub-devices (clock first):")
for d in chosen { printDevice(d, indent: "  ") }
if Set(chosen.map(\.nominalRate)).count > 1 {
    print("note: sub-devices report different nominal rates; the HAL must resample or reconfigure.")
}

let aggregate: PrivateAggregate
do { aggregate = try PrivateAggregate(subDevices: chosen) } catch { fail("\(error)") }
let rate = aggregate.nominalRate
print(String(format: "aggregate id=%u rate=%.0f channels=%d", aggregate.id, rate, outputChannelCount(aggregate.id)))
for d in chosen {
    if let now = describeDevice(d.id), now.nominalRate != d.nominalRate {
        print(String(format: "note: %@ rate changed %.0f -> %.0f after aggregation", d.name, d.nominalRate, now.nominalRate))
    }
}

var maps: [Player.OutputMap] = []
var offset = 0
for d in chosen {
    maps.append(.init(channelOffset: offset, channelCount: min(d.outputChannels, 2)))
    offset += d.outputChannels
}

let source: Source
do {
    source = click ? Source.clickTrack(sampleRate: rate) : try Source.load(url: URL(fileURLWithPath: filePath!), sampleRate: rate)
} catch { aggregate.destroy(); fail("decode: \(error)") }

let player: Player
do { player = try Player(aggregateID: aggregate.id, sampleRate: rate, outputs: maps, source: source) } catch {
    aggregate.destroy(); fail("\(error)")
}
for n in 0..<maps.count { player.setDelay(output: n, ms: initialDelays[n]) }
player.setMaster(initialMaster)

var overloads = 0
var shuttingDown = false

func shutdown(_ code: Int32, _ reason: String) -> Never {
    if !shuttingDown {
        shuttingDown = true
        print(reason)
        player.stop()
        aggregate.destroy()
    }
    exit(code)
}

// Device health: stop (never reroute) if any sub-device or the aggregate goes away
// or the aggregate's sample rate changes underneath us.
let system = AudioObjectID(kAudioObjectSystemObject)
var devicesAddr = propAddr(kAudioHardwarePropertyDevices)
AudioObjectAddPropertyListenerBlock(system, &devicesAddr, .main) { _, _ in
    let present = Set(allOutputDevices().map(\.uid))
    let missing = chosen.filter { !present.contains($0.uid) }.map(\.name)
    if !missing.isEmpty { shutdown(3, "DEVICE LOST: \(missing.joined(separator: ", ")) — playback stopped") }
}
for (id, name) in [(aggregate.id, "aggregate")] + chosen.map({ ($0.id, $0.name) }) {
    var aliveAddr = propAddr(kAudioDevicePropertyDeviceIsAlive)
    AudioObjectAddPropertyListenerBlock(id, &aliveAddr, .main) { _, _ in
        if (readScalar(id, propAddr(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) == 0 {
            shutdown(3, "DEVICE LOST: \(name) — playback stopped")
        }
    }
}
var rateAddr = propAddr(kAudioDevicePropertyNominalSampleRate)
AudioObjectAddPropertyListenerBlock(aggregate.id, &rateAddr, .main) { _, _ in
    shutdown(4, String(format: "FORMAT CHANGE: aggregate rate is now %.0f — playback stopped", aggregate.nominalRate))
}
var overloadAddr = propAddr(kAudioDeviceProcessorOverload)
AudioObjectAddPropertyListenerBlock(aggregate.id, &overloadAddr, .main) { _, _ in overloads += 1 }

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { shutdown(0, "interrupted") }
sigint.resume()

func status() -> String {
    var s = String(format: "t=%7.1fs/%.1fs %@", player.positionSeconds, player.durationSeconds,
                   player.ended.load(ordering: .relaxed) ? "ENDED" : (player.paused.load(ordering: .relaxed) ? "paused" : "playing"))
    for n in 0..<maps.count {
        s += String(format: " | out%d %@ delay=%.1fms gain=%.2f", n + 1, chosen[n].name, player.delayMs(output: n), player.gain(output: n))
    }
    return s + String(format: " | master=%.2f overloads=%d", player.master, overloads)
}

func handle(_ line: String) {
    let parts = line.split(separator: " ").map(String.init)
    guard let cmd = parts.first else { return }
    func outIndex(_ s: String) -> Int? {
        guard let n = Int(s), (1...maps.count).contains(n) else { print("bad output index"); return nil }
        return n - 1
    }
    switch cmd {
    case "q": shutdown(0, "bye")
    case "p": player.paused.store(!player.paused.load(ordering: .relaxed), ordering: .relaxed)
    case "i": for d in chosen { if let now = describeDevice(d.id) { printDevice(now, indent: "  ") } }
    case "s" where parts.count == 2:
        guard let sec = Double(parts[1]), sec >= 0, sec <= player.durationSeconds else { print("seek 0...\(player.durationSeconds)"); return }
        player.seek(seconds: sec)
        if player.paused.load(ordering: .relaxed) && !click { player.paused.store(false, ordering: .relaxed) }
    case "m" where parts.count == 2:
        guard let g = Float(parts[1]), (0...1).contains(g) else { print("master 0...1"); return }
        player.setMaster(g)
    case "g" where parts.count == 3:
        guard let n = outIndex(parts[1]), let g = Float(parts[2]), (0...1).contains(g) else { print("gain 0...1"); return }
        player.setGain(output: n, g)
    case "d" where parts.count == 3:
        guard let n = outIndex(parts[1]) else { return }
        let arg = parts[2]
        guard let v = Double(arg) else { print("bad ms"); return }
        let ms = (arg.hasPrefix("+") || arg.hasPrefix("-")) ? player.delayMs(output: n) + v : v
        guard (0...2000).contains(ms) else { print("delay must stay within 0...2000 ms"); return }
        player.setDelay(output: n, ms: ms)
    default: print("unknown command (q to quit)"); return
    }
    print(status())
}

let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
stdinSource.setEventHandler {
    guard let line = readLine() else { stdinSource.cancel(); return }
    handle(line.trimmingCharacters(in: .whitespaces))
}
stdinSource.resume()

let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 10, repeating: 10)
ticker.setEventHandler { print(status()) }
ticker.resume()

do { try player.start() } catch { shutdown(1, "\(error)") }
print("playing. type commands (q to quit).")
print(status())
dispatchMain()
