import Foundation

/// Per-speaker settings. `uid` is the CoreAudio device UID (stable for a given
/// Bluetooth speaker); `name` is kept as a fallback hint if the UID ever changes.
struct SavedOutput: Codable, Equatable, Sendable {
    var uid: String
    var name: String
    var delayMs: Double
    var gain: Double
    /// Optional peak limiter for this speaker only. The ceiling is kept while off.
    var limitEnabled: Bool? = nil
    var limitDb: Double? = nil

    var effectiveLimitDb: Double { limitDb ?? -12 }
    /// The ceiling to apply, or nil when the limiter is off.
    var activeLimitDb: Double? { limitEnabled == true ? effectiveLimitDb : nil }
}

struct Profile: Codable, Sendable {
    var name: String
    var outputs: [SavedOutput]
    var master: Double
    var savedAt: Date
}

struct Config: Codable, Sendable {
    var token: String
    /// Current selection in aggregate order: the first entry is the clock device.
    var outputs: [SavedOutput] = []
    var master: Double = 0.5
    var profiles: [Profile] = []
    /// nil means the calibration click track.
    var currentTrackID: String?
    /// Live Mac audio instead of a file: "all" or an app bundle ID. Takes precedence over currentTrackID.
    var liveTarget: String?
}

struct Track: Codable, Sendable {
    var id: String
    var name: String
    var fileName: String
    var bytes: Int
    var durationSeconds: Double
    var addedAt: Date
}

/// JSON files under ~/Library/Application Support/SpeakerSync (override with SSYNC_HOME).
/// Uploaded audio lives in `library/` until deleted through the API.
final class Store: @unchecked Sendable {
    let root: URL
    let libraryDir: URL
    private var configURL: URL { root.appendingPathComponent("config.json") }
    private var tracksURL: URL { root.appendingPathComponent("tracks.json") }

    init() throws {
        if let home = ProcessInfo.processInfo.environment["SSYNC_HOME"], !home.isEmpty {
            root = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpeakerSync", isDirectory: true)
        }
        libraryDir = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // Remove partial uploads left by a crash.
        for f in (try? FileManager.default.contentsOfDirectory(atPath: libraryDir.path)) ?? [] where f.hasPrefix(".upload-") {
            try? FileManager.default.removeItem(at: libraryDir.appendingPathComponent(f))
        }
    }

    func loadConfig() throws -> Config {
        if let data = try? Data(contentsOf: configURL) {
            return try decoder.decode(Config.self, from: data)
        }
        let config = Config(token: Store.newToken())
        try saveConfig(config)
        return config
    }

    func saveConfig(_ config: Config) throws {
        try encoder.encode(config).write(to: configURL, options: .atomic)
        // The token is a secret: owner-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    func loadTracks() -> [Track] {
        guard let data = try? Data(contentsOf: tracksURL) else { return [] }
        return (try? decoder.decode([Track].self, from: data)) ?? []
    }

    func saveTracks(_ tracks: [Track]) throws {
        try encoder.encode(tracks).write(to: tracksURL, options: .atomic)
    }

    func trackURL(_ t: Track) -> URL { libraryDir.appendingPathComponent(t.fileName) }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
