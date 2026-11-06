import Foundation

/// An error with an HTTP status, surfaced to the browser as {"error": message}.
struct APIError: Error, Sendable {
    let status: Int
    let message: String
    static func bad(_ m: String) -> APIError { APIError(status: 400, message: m) }
    static func notFound(_ m: String) -> APIError { APIError(status: 404, message: m) }
    static func conflict(_ m: String) -> APIError { APIError(status: 409, message: m) }
}

enum Limits {
    static let maxDelayMs = 2000.0
    static let maxOutputs = 2
    static let maxUploadBytes = 500 * 1024 * 1024
    static let maxLibraryBytes = 5 * 1024 * 1024 * 1024
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
    static let maxProfileNameLength = 40
}

enum Validate {
    static func delayMs(_ v: Double) throws -> Double {
        guard v.isFinite, v >= 0, v <= Limits.maxDelayMs else { throw APIError.bad("delayMs must be 0...\(Int(Limits.maxDelayMs))") }
        return v
    }

    static func gain(_ v: Double) throws -> Double {
        guard v.isFinite, v >= 0, v <= 1 else { throw APIError.bad("gain must be 0...1") }
        return v
    }

    static func seek(_ v: Double, duration: Double) throws -> Double {
        guard v.isFinite, v >= 0, v <= duration else { throw APIError.bad("seconds must be 0...\(duration)") }
        return v
    }

    /// 1–2 distinct UIDs, each currently present.
    static func outputUIDs(_ uids: [String], present: Set<String>) throws -> [String] {
        guard (1...Limits.maxOutputs).contains(uids.count) else { throw APIError.bad("select 1 or 2 outputs") }
        guard Set(uids).count == uids.count else { throw APIError.bad("outputs must be distinct") }
        for u in uids where !present.contains(u) { throw APIError.bad("output not connected: \(u)") }
        return uids
    }

    /// Returns (display name, lowercase extension). Rejects paths and unknown types.
    static func uploadName(_ raw: String?) throws -> (String, String) {
        guard let raw, !raw.isEmpty, raw.count <= 200 else { throw APIError.bad("name query parameter required (max 200 chars)") }
        let base = (raw as NSString).lastPathComponent
        guard base == raw, !base.hasPrefix("."), !base.contains("\0") else { throw APIError.bad("invalid file name") }
        let ext = (base as NSString).pathExtension.lowercased()
        guard Limits.audioExtensions.contains(ext) else {
            throw APIError(status: 415, message: "unsupported file type; allowed: \(Limits.audioExtensions.sorted().joined(separator: ", "))")
        }
        return (base, ext)
    }

    /// "all", or a reverse-DNS bundle ID such as com.spotify.client.
    static func liveTarget(_ raw: String) throws -> String {
        if raw == "all" { return raw }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard (3...100).contains(raw.count), raw.contains("."), !raw.hasPrefix("."), !raw.hasSuffix("."),
              raw.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            throw APIError.bad("live must be \"all\" or an app bundle ID like com.spotify.client")
        }
        return raw
    }

    static func profileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        guard !name.isEmpty, name.count <= Limits.maxProfileNameLength,
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw APIError.bad("profile name: 1-\(Limits.maxProfileNameLength) letters, digits, space, - _ .")
        }
        return name
    }
}

/// How a saved output was found among the devices present now.
enum MatchKind: String, Codable, Sendable { case uid, name, missing }

struct PresentDevice: Sendable { let uid: String; let name: String }

/// Match saved outputs to present devices: by UID first; by display name only
/// when exactly one unclaimed present device has that name.
func matchOutputs(_ saved: [SavedOutput], present: [PresentDevice]) -> [(saved: SavedOutput, uid: String?, kind: MatchKind)] {
    var claimed = Set<String>()
    var result: [(SavedOutput, String?, MatchKind)] = saved.map { s in
        if present.contains(where: { $0.uid == s.uid }) { claimed.insert(s.uid); return (s, s.uid, .uid) }
        return (s, nil, .missing)
    }
    for i in result.indices where result[i].2 == .missing {
        let candidates = present.filter { $0.name == result[i].0.name && !claimed.contains($0.uid) }
        if candidates.count == 1 {
            claimed.insert(candidates[0].uid)
            result[i] = (result[i].0, candidates[0].uid, .name)
        }
    }
    return result.map { (saved: $0.0, uid: $0.1, kind: $0.2) }
}

/// Constant-time comparison for the bearer token.
func tokensEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}

/// True for loopback, RFC 1918, link-local and IPv6 unique-local addresses.
func isLocalNetworkAddress(_ ip: String) -> Bool {
    var s = ip.lowercased()
    if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
    if s.contains(":") {
        return s == "::1" || s.hasPrefix("fe8") || s.hasPrefix("fe9") || s.hasPrefix("fea") || s.hasPrefix("feb")
            || s.hasPrefix("fc") || s.hasPrefix("fd")
    }
    let p = s.split(separator: ".").compactMap { Int($0) }
    guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
    switch (p[0], p[1]) {
    case (127, _), (10, _), (192, 168), (169, 254): return true
    case (172, 16...31): return true
    default: return false
    }
}
