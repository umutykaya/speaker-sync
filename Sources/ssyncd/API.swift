import Foundation
import Hummingbird

struct AppContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteIP: String?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteIP = source.channel.remoteAddress?.ipAddress
    }
}

/// Rejects anything not from loopback / the local network, then requires the
/// bearer token on /api/*. Static files (no secrets) need only the LAN check.
struct AccessMiddleware: RouterMiddleware {
    typealias Context = AppContext
    let token: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let ip = context.remoteIP, isLocalNetworkAddress(ip) else {
            return errorResponse(APIError(status: 403, message: "local network only"))
        }
        if request.uri.path.hasPrefix("/api/") && request.uri.path != "/api/health" {
            let auth = request.headers[.authorization] ?? ""
            guard auth.hasPrefix("Bearer "), tokensEqual(String(auth.dropFirst(7)), token) else {
                return errorResponse(APIError(status: 401, message: "missing or wrong token; open the pairing link printed by ssyncd"))
            }
        }
        do {
            var response = try await next(request, context)
            response.headers[.contentSecurityPolicy] = "default-src 'self'; frame-ancestors 'none'"
            response.headers[.xContentTypeOptions] = "nosniff"
            response.headers[.init("Referrer-Policy")!] = "no-referrer"
            return response
        } catch let e as APIError {
            return errorResponse(e)
        } catch let e as HTTPError {
            return errorResponse(APIError(status: Int(e.status.code), message: e.body ?? e.status.reasonPhrase))
        } catch is DecodingError {
            return errorResponse(APIError.bad("malformed JSON body"))
        }
    }
}

func errorResponse(_ e: APIError) -> Response {
    let body = (try? JSONEncoder().encode(["error": e.message])) ?? Data()
    return Response(status: .init(code: e.status), headers: [.contentType: "application/json", .cacheControl: "no-store"],
                    body: .init(byteBuffer: ByteBuffer(data: body)))
}

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
             body: .init(byteBuffer: ByteBuffer(data: try jsonEncoder.encode(value))))
}

/// Path parameters arrive percent-encoded ("Living%20room").
func profileParam(_ ctx: AppContext) throws -> String {
    let raw = try ctx.parameters.require("name")
    guard let name = raw.removingPercentEncoding else { throw APIError.bad("bad profile name encoding") }
    return name
}

struct SelectOutputsBody: Decodable { let uids: [String] }
struct TransportBody: Decodable { let action: String }
struct SeekBody: Decodable { let seconds: Double }
struct GainBody: Decodable { let gain: Double }
struct OutputBody: Decodable {
    let uid: String
    let delayMs: Double?
    let gain: Double?
    let limitEnabled: Bool?
    let limitDb: Double?
}
struct SourceBody: Decodable { let trackId: String?; let live: String? }
struct ProfileBody: Decodable { let name: String }

func buildRouter(controller: Controller, store: Store, token: String, webRoot: String?) -> Router<AppContext> {
    let router = Router(context: AppContext.self)
    router.add(middleware: AccessMiddleware(token: token))
    if let webRoot {
        router.add(middleware: FileMiddleware(webRoot, cacheControl: .init([(MediaType(type: .any), [.noCache])]), searchForIndexHtml: true))
    }

    router.get("/api/health") { _, _ in try json(["ok": true]) }

    let api = router.group("api")
    api.get("state") { _, _ in try json(await controller.state()) }

    api.post("transport") { req, ctx in
        let b = try await req.decode(as: TransportBody.self, context: ctx)
        try await MainActor.run {
            switch b.action {
            case "play": try controller.play()
            case "pause": try controller.pause()
            case "stop": try controller.stop()
            default: throw APIError.bad("action must be play, pause or stop")
            }
        }
        return try json(await controller.state())
    }
    api.post("seek") { req, ctx in
        let b = try await req.decode(as: SeekBody.self, context: ctx)
        try await MainActor.run { try controller.seek(b.seconds) }
        return try json(await controller.state())
    }
    api.post("master") { req, ctx in
        let b = try await req.decode(as: GainBody.self, context: ctx)
        try await MainActor.run { try controller.setMaster(b.gain) }
        return try json(await controller.state())
    }
    api.post("output") { req, ctx in
        let b = try await req.decode(as: OutputBody.self, context: ctx)
        try await MainActor.run {
            try controller.setOutput(uid: b.uid, delayMs: b.delayMs, gain: b.gain, limitEnabled: b.limitEnabled, limitDb: b.limitDb)
        }
        return try json(await controller.state())
    }
    api.post("outputs") { req, ctx in
        let b = try await req.decode(as: SelectOutputsBody.self, context: ctx)
        try await controller.selectOutputs(b.uids)
        return try json(await controller.state())
    }
    api.post("source") { req, ctx in
        let b = try await req.decode(as: SourceBody.self, context: ctx)
        if let live = b.live {
            try await controller.setLiveSource(live)
        } else {
            try await controller.setSource(trackID: b.trackId)
        }
        return try json(await controller.state())
    }
    api.post("reconnect") { _, _ in
        await controller.reconnect()
        return try json(await controller.state())
    }

    // Raw-body upload: PUT /api/tracks?name=song.mp3 with the file as the body.
    api.put("tracks") { req, _ in
        let (name, ext) = try Validate.uploadName(req.uri.queryParameters.get("name"))
        let used = await controller.libraryBytes
        let temp = store.libraryDir.appendingPathComponent(".upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else {
            throw APIError(status: 500, message: "cannot create upload file")
        }
        var bytes = 0
        do {
            defer { try? handle.close() }
            for try await chunk in req.body {
                bytes += chunk.readableBytes
                if bytes > Limits.maxUploadBytes { throw APIError(status: 413, message: "file larger than \(Limits.maxUploadBytes / 1_048_576) MB") }
                if used + bytes > Limits.maxLibraryBytes { throw APIError(status: 507, message: "library full; delete tracks first") }
                try handle.write(contentsOf: chunk.readableBytesView)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard bytes > 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw APIError.bad("empty upload")
        }
        let track = try await controller.addTrack(tempFile: temp, name: name, ext: ext, bytes: bytes)
        return try json(track, status: .created)
    }
    api.delete("tracks/:id") { _, ctx in
        let id = try ctx.parameters.require("id")
        try await controller.deleteTrack(id)
        return try json(await controller.state())
    }

    api.post("profiles") { req, ctx in
        let b = try await req.decode(as: ProfileBody.self, context: ctx)
        try await MainActor.run { try controller.saveProfile(b.name) }
        return try json(await controller.state())
    }
    api.post("profiles/:name/load") { _, ctx in
        try await controller.loadProfile(try profileParam(ctx))
        return try json(await controller.state())
    }
    api.delete("profiles/:name") { _, ctx in
        let name = try profileParam(ctx)
        try await MainActor.run { try controller.deleteProfile(name) }
        return try json(await controller.state())
    }
    return router
}
