import Foundation

/// Source of response bytes for a tunnel-proxied request. Implementations
/// stream file bytes from disk; the app supplies one when opening a tunnel.
public protocol TunnelResponder: AnyObject, Sendable {
    /// Called on the tunnel's IO task. Should call `writer` for head + each
    /// body chunk. Returning ends the response (edge receives OpEnd).
    func handle(
        method: String,
        path: String,
        writer: TunnelResponseWriter
    ) async throws
}

/// Handed to a TunnelResponder. Calls map 1:1 to wire frames.
public final class TunnelResponseWriter: @unchecked Sendable {
    private let send: @Sendable (TunnelFrame) async -> Void
    private let requestID: Data
    private var wroteHead = false

    init(requestID: Data, send: @escaping @Sendable (TunnelFrame) async -> Void) {
        self.requestID = requestID
        self.send = send
    }

    public func writeHead(status: Int, headers: [String: String] = [:]) async throws {
        precondition(!wroteHead, "head already sent")
        wroteHead = true
        let h = HeadMessage(status: status,
                            headers: headers.mapValues { [$0] })
        let data = try JSONEncoder().encode(h)
        await send(TunnelFrame(op: .head, requestID: requestID, payload: data))
    }

    public func writeChunk(_ chunk: Data) async {
        await send(TunnelFrame(op: .body, requestID: requestID, payload: chunk))
    }

    public func end() async {
        await send(TunnelFrame(op: .end, requestID: requestID))
    }

    public func writeError(_ message: String) async {
        await send(TunnelFrame(op: .err, requestID: requestID, payload: Data(message.utf8)))
    }
}

public enum TunnelClientState: Equatable {
    case idle
    case connecting
    case open
    case closing
    case closed(reason: String?)
}

/// Maintains an outbound WebSocket to the backend, reads OpOpen frames, and
/// dispatches each to the TunnelResponder. Writes are serialized through an
/// actor-guarded URLSessionWebSocketTask.
public final class TunnelClient: @unchecked Sendable {
    public private(set) var state: TunnelClientState = .idle

    private let baseURL: URL
    private let shareID: String
    private let jwt: String
    private let responder: TunnelResponder
    private var task: URLSessionWebSocketTask?
    private let writeQueue = AsyncSerialQueue()

    public init(baseURL: URL, shareID: String, jwt: String, responder: TunnelResponder) {
        self.baseURL = baseURL
        self.shareID = shareID
        self.jwt = jwt
        self.responder = responder
    }

    public func start() {
        guard state == .idle || isClosed else { return }
        state = .connecting

        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/v1/tunnel"
        comps.queryItems = [
            .init(name: "share", value: shareID),
            .init(name: "token", value: jwt),
        ]
        let req = URLRequest(url: comps.url!)
        let session = URLSession(configuration: .default)
        let t = session.webSocketTask(with: req)
        self.task = t
        t.resume()
        state = .open
        receiveLoop()
    }

    public func stop(reason: String? = nil) {
        state = .closing
        task?.cancel(with: .normalClosure, reason: reason?.data(using: .utf8))
        task = nil
        state = .closed(reason: reason)
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    private func receiveLoop() {
        guard let t = task else { return }
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.state = .closed(reason: err.localizedDescription)
            case .success(let msg):
                self.handle(message: msg)
                self.receiveLoop()
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let raw: Data
        switch message {
        case .data(let d): raw = d
        case .string(let s): raw = Data(s.utf8)
        @unknown default: return
        }
        guard let frame = TunnelFrame.decode(raw) else { return }
        guard frame.op == .open else {
            // For MVP we only handle OpOpen and OpCancel on the sender side.
            return
        }
        dispatch(frame: frame)
    }

    private func dispatch(frame: TunnelFrame) {
        guard let header = try? JSONDecoder().decode(OpenHeader.self, from: frame.payload) else {
            return
        }
        let writer = TunnelResponseWriter(requestID: frame.requestID) { [weak self] f in
            await self?.send(frame: f)
        }
        Task.detached { [responder = self.responder] in
            do {
                try await responder.handle(method: header.method, path: header.path, writer: writer)
                await writer.end()
            } catch {
                await writer.writeError(error.localizedDescription)
                await writer.end()
            }
        }
    }

    private func send(frame: TunnelFrame) async {
        let data = frame.encode()
        await writeQueue.run { [weak self] in
            try? await self?.task?.send(.data(data))
        }
    }
}

/// Tiny actor-backed serial queue so writes don't interleave.
actor AsyncSerialQueue {
    private var tail: Task<Void, Never> = Task {}
    func run(_ body: @Sendable @escaping () async -> Void) async {
        let prev = tail
        tail = Task {
            _ = await prev.value
            await body()
        }
        await tail.value
    }
}
