import Foundation
import Hummingbird

@main
struct SSyncD {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        if CommandLine.arguments.contains("--rotate-token") {
            var config = try store.loadConfig()
            config.token = Store.newToken()
            try store.saveConfig(config)
            print("token rotated; old pairing links no longer work. Restart the service to apply.")
            return
        }
        let controller = try await MainActor.run { try Controller(store: store) }
        let token = controller.config.token

        let env = ProcessInfo.processInfo.environment
        let host = env["SSYNC_HOST"] ?? "0.0.0.0"
        let port = Int(env["SSYNC_PORT"] ?? "") ?? 8095

        // Restore saved outputs, paused. Never auto-plays after a restart.
        await controller.rebuild()

        let webRoot = findWebRoot()
        print("[ssyncd] settings: \(store.root.path)")
        print("[ssyncd] web UI: \(webRoot ?? "not found (run `npm run build` in web/, or set SSYNC_WEB)")")
        print("[ssyncd] listening on \(host):\(port)")
        for ip in lanAddresses() {
            print("[ssyncd] pairing link: http://\(ip):\(port)/#token=\(token)")
        }
        let app = Application(
            router: buildRouter(controller: controller, store: store, token: token, webRoot: webRoot),
            configuration: .init(address: .hostname(host, port: port), serverName: "ssyncd")
        )
        try await app.runService()
    }
}

/// IPv4 addresses on active Ethernet/Wi-Fi interfaces, for the pairing link.
func lanAddresses() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              String(cString: ptr.pointee.ifa_name).hasPrefix("en") else { continue }  // skip VM/container bridges
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if isLocalNetworkAddress(ip) && !ip.hasPrefix("169.254.") { result.append(ip) }
        }
    }
    return result
}

/// The built web UI: $SSYNC_WEB, else web/dist found by walking up from the
/// executable (works for .build/release/ssyncd), else ./web/dist.
func findWebRoot() -> String? {
    let fm = FileManager.default
    let has = { (dir: String) in fm.fileExists(atPath: (dir as NSString).appendingPathComponent("index.html")) }
    if let env = ProcessInfo.processInfo.environment["SSYNC_WEB"], !env.isEmpty { return has(env) ? env : nil }
    var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<5 {
        guard let d = dir else { break }
        let candidate = d.appendingPathComponent("web/dist").path
        if has(candidate) { return candidate }
        dir = d.deletingLastPathComponent()
    }
    let cwd = fm.currentDirectoryPath + "/web/dist"
    return has(cwd) ? cwd : nil
}
