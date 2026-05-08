#if canImport(Network)
import Foundation
import Network

/// LANHost is an embedded HTTP server for LAN-only transfers. No backend
/// required: the sender broadcasts a Bonjour `_porta._tcp.` service on the
/// local wifi network, the receiver discovers it (by hostname + port) and
/// opens `http://<host>.local:<port>/share`.
///
/// This is deliberately minimal — we only parse GET/HEAD request lines and
/// synthesize one of two responses:
///   GET /share          → share manifest as JSON
///   GET /files/<name>   → file bytes (streamed)
///
/// The shared core serializer (TunnelResponder) is reused so the same
/// FileServer code answers both LAN and global requests.
public final class LANHost: @unchecked Sendable {
    public struct ShareManifest: Codable {
        public let title: String?
        public let files: [ShareFile]
    }

    private let manifest: ShareManifest
    private let responder: TunnelResponder
    private let serviceType: String
    private let serviceName: String
    private let queue = DispatchQueue(label: "porta.lan")

    private var listener: NWListener?
    private(set) public var port: UInt16 = 0

    public init(
        manifest: ShareManifest,
        responder: TunnelResponder,
        serviceType: String = "_porta._tcp.",
        serviceName: String = "Porta"
    ) {
        self.manifest = manifest
        self.responder = responder
        self.serviceType = serviceType
        self.serviceName = serviceName
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: serviceName, type: serviceType)

        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state,
                  let rawPort = listener.port?.rawValue else { return }
            self?.port = rawPort
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(on: conn)
    }

    private func receiveRequest(on conn: NWConnection, accumulated: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            var buf = accumulated
            if let d = data { buf.append(d) }

            // Request line + headers terminated by \r\n\r\n.
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = buf[..<end.lowerBound]
                self.dispatch(header: header, on: conn)
                return
            }
            if isComplete || err != nil {
                conn.cancel()
                return
            }
            self.receiveRequest(on: conn, accumulated: buf)
        }
    }

    private func dispatch(header: Data, on conn: NWConnection) {
        guard let text = String(data: header, encoding: .utf8) else {
            self.respond(conn, status: 400, body: Data("bad request".utf8))
            return
        }
        let first = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            respond(conn, status: 400, body: Data("bad request".utf8))
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])

        if path == "/share" {
            let data = (try? JSONEncoder().encode(manifest)) ?? Data()
            respond(conn, status: 200, headers: ["Content-Type": "application/json"], body: data)
            return
        }

        // Defer to the shared TunnelResponder for /files/<name>.
        let writer = LANResponseWriter(conn: conn)
        Task { [responder] in
            do {
                try await responder.handle(method: method, path: path, writer: writer.asTunnelWriter())
                await writer.end()
            } catch {
                await writer.fail(error)
            }
        }
    }

    private func respond(
        _ conn: NWConnection,
        status: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        var resp = "HTTP/1.1 \(status) \(httpText(status))\r\n"
        var merged = headers
        merged["Content-Length"] = String(body.count)
        merged["Connection"] = "close"
        for (k, v) in merged { resp += "\(k): \(v)\r\n" }
        resp += "\r\n"
        var out = Data(resp.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func httpText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default:  return "OK"
        }
    }
}

/// Adapts an NWConnection to the TunnelResponseWriter interface so a single
/// FileServer implementation can serve both tunnel and LAN clients.
final class LANResponseWriter: @unchecked Sendable {
    private let conn: NWConnection
    private var wroteHead = false

    init(conn: NWConnection) { self.conn = conn }

    func writeHead(status: Int, headers: [String: String]) async {
        guard !wroteHead else { return }
        wroteHead = true
        var line = "HTTP/1.1 \(status) OK\r\n"
        var merged = headers
        merged["Connection"] = "close"
        for (k, v) in merged { line += "\(k): \(v)\r\n" }
        line += "\r\n"
        await send(Data(line.utf8))
    }

    func writeChunk(_ data: Data) async { await send(data) }
    func end() async { conn.cancel() }
    func fail(_ error: Error) async {
        await send(Data("HTTP/1.1 500 Internal\r\nConnection: close\r\n\r\n\(error)".utf8))
        conn.cancel()
    }

    func send(_ data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    /// Bridges this LAN writer into a TunnelResponseWriter so the same
    /// TunnelResponder can drive both code paths. We use a private sender
    /// closure that emits synthetic frames.
    func asTunnelWriter() -> TunnelResponseWriter {
        TunnelResponseWriter(requestID: Data(count: 16)) { [weak self] frame in
            guard let self else { return }
            switch frame.op {
            case .head:
                if let head = try? JSONDecoder().decode(HeadMessage.self, from: frame.payload) {
                    let flat = head.headers?.mapValues { $0.first ?? "" } ?? [:]
                    await self.writeHead(status: head.status, headers: flat)
                }
            case .body: await self.writeChunk(frame.payload)
            case .end:  await self.end()
            case .err:  await self.fail(NSError(
                domain: "porta.lan", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(data: frame.payload, encoding: .utf8) ?? ""]))
            default: break
            }
        }
    }
}
#endif
