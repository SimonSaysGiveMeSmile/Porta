import Foundation
import PortaCore
import SwiftUI

enum ConnectionState: Equatable {
    case unknown
    case connecting
    case online
    case offline(reason: String)

    var isOnline: Bool { if case .online = self { return true } else { return false } }
}

/// Active transfer modes. LAN mode runs an embedded HTTP server on the
/// sender's device and needs no backend; backend mode uses the reverse
/// tunnel. The user can pick a default in Settings; the app will also
/// auto-fall-back to LAN when the backend is unreachable.
enum TransferMode: String, Codable {
    case lan
    case backend
}

@MainActor
final class AppState: ObservableObject {
    // Identity + networking
    @Published var identity: DeviceIdentity?
    @Published var deviceID: String?
    @Published var connection: ConnectionState = .unknown

    // Shares
    @Published var activeShare: ActiveShare?
    @Published var pendingApprovals: [PendingApproval] = []
    @Published var history: [ShareHistoryEntry] = []
    @Published var errorMessage: String?

    // Preferences
    @Published var backendURLString: String {
        didSet {
            UserDefaults.standard.set(backendURLString, forKey: Self.backendKey)
            rebuildAPI()
        }
    }
    @Published var preferredMode: TransferMode {
        didSet { UserDefaults.standard.set(preferredMode.rawValue, forKey: Self.modeKey) }
    }

    private(set) var api: PortaAPI
    private let historyStore = ShareHistoryStore()
    var baseURL: URL { URL(string: backendURLString) ?? Self.defaultBackend }

    static let backendKey = "porta.backendURL"
    static let modeKey = "porta.preferredMode"
    static let defaultBackend = URL(string: "http://localhost:8080")!

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.backendKey)
            ?? Self.defaultBackend.absoluteString
        self.backendURLString = saved
        let modeRaw = UserDefaults.standard.string(forKey: Self.modeKey) ?? TransferMode.lan.rawValue
        self.preferredMode = TransferMode(rawValue: modeRaw) ?? .lan
        self.api = PortaAPI(baseURL: URL(string: saved) ?? Self.defaultBackend)
        self.identity = DeviceIdentity.loadOrCreate()
        self.history = historyStore.load()
    }

    private func rebuildAPI() {
        self.api = PortaAPI(baseURL: baseURL)
        self.deviceID = nil
        self.connection = .unknown
    }

    /// Probes the backend. Safe to call repeatedly and never throws — on
    /// failure we surface `connection = .offline(reason)` and the app
    /// continues working in LAN mode.
    func connect() async {
        guard let ident = identity else {
            connection = .offline(reason: "no identity"); return
        }
        connection = .connecting
        do {
            let nonce = try await api.nonce()
            guard let nonceBytes = Data(base64URL: nonce.nonce) else {
                connection = .offline(reason: "bad nonce"); return
            }
            let sig = ident.signer(nonceBytes)
            let verify = try await api.verify(
                publicKey: ident.publicKey,
                nonce: nonce.nonce,
                signature: sig,
                apns: nil
            )
            await api.setJWT(verify.jwt)
            self.deviceID = verify.device_id
            self.connection = .online
        } catch {
            self.connection = .offline(reason: friendly(error))
        }
    }

    private func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "can't reach server"
            case NSURLErrorTimedOut:           return "server timed out"
            case NSURLErrorNotConnectedToInternet: return "no internet"
            default: return "network error"
            }
        }
        return error.localizedDescription
    }

    // MARK: - Share creation

    /// Creates a share using the user's preferred mode. If backend is the
    /// preference but unreachable, we fall back to LAN so the user never
    /// gets stuck just because a server is down.
    func createShare(from urls: [URL], title: String?) async {
        do {
            if preferredMode == .backend {
                if !connection.isOnline { await connect() }
                if connection.isOnline {
                    try await createBackendShare(from: urls, title: title)
                    return
                }
                // Backend down — fall back to LAN with a user-visible note.
                errorMessage = "Backend unreachable, using LAN only."
            }
            try createLANShare(from: urls, title: title)
        } catch {
            errorMessage = "Create failed: \(friendly(error))"
        }
    }

    private func createLANShare(from urls: [URL], title: String?) throws {
        let files = makeShareFiles(urls: urls)
        let fileMap = Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, $0) })
        let responder = FileServer(files: fileMap)

        let manifest = LANHost.ShareManifest(title: title, files: files)
        let host = LANHost(manifest: manifest, responder: responder)
        try host.start()

        // NWListener reports port asynchronously; give it a moment.
        let port = waitForPort(host: host, timeout: 1.0)
        let url = LANAddress.shareURL(port: port)

        let active = ActiveShare(kind: .lan, title: title, shareURL: url,
                                 files: files, backend: nil, lan: host)
        self.activeShare = active
        recordHistory(active: active)
    }

    private func createBackendShare(from urls: [URL], title: String?) async throws {
        let files = makeShareFiles(urls: urls)
        let share = try await api.createShare(title: title, files: files)
        let fileMap = Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, $0) })
        let responder = FileServer(files: fileMap)
        let client = TunnelClient(
            baseURL: baseURL, shareID: share.id,
            jwt: await api.currentJWT() ?? "",
            responder: responder
        )
        client.start()
        let active = ActiveShare(kind: .backend, title: title,
                                 shareURL: share.share_url, files: files,
                                 backend: (share, client), lan: nil)
        self.activeShare = active
        recordHistory(active: active)
    }

    private func makeShareFiles(urls: [URL]) -> [ShareFile] {
        urls.compactMap {
            let size = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? 0
            return ShareFile(name: $0.lastPathComponent, size: size)
        }
    }

    private func waitForPort(host: LANHost, timeout: TimeInterval) -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while host.port == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return host.port == 0 ? 0 : host.port
    }

    private func recordHistory(active: ActiveShare) {
        let total = active.files.reduce(Int64(0)) { $0 + $1.size }
        let entry = ShareHistoryEntry(
            kind: active.kind == .lan ? .lan : .backend,
            title: active.title,
            shareURL: active.shareURL,
            fileNames: active.files.map(\.name),
            totalBytes: total
        )
        self.history = historyStore.prepend(entry)
    }

    func deleteHistoryEntry(_ entry: ShareHistoryEntry) {
        self.history = historyStore.remove(id: entry.id)
    }

    func clearHistory() {
        historyStore.clear()
        self.history = []
    }

    // MARK: - Approval flow (backend only)

    func approve(_ approval: PendingApproval) async {
        do {
            try await api.approve(sessionID: approval.sessionID)
            pendingApprovals.removeAll { $0.id == approval.id }
        } catch {
            errorMessage = "Approve failed: \(friendly(error))"
        }
    }

    func reject(_ approval: PendingApproval) async {
        try? await api.reject(sessionID: approval.sessionID)
        pendingApprovals.removeAll { $0.id == approval.id }
    }
}

/// Unified representation of whatever share is currently live. Only one of
/// `backend` / `lan` is non-nil, determined by `kind`.
struct ActiveShare: Identifiable {
    enum Kind { case lan, backend }

    let id = UUID()
    let kind: Kind
    let title: String?
    let shareURL: String
    let files: [ShareFile]
    let backend: (share: CreatedShare, tunnel: TunnelClient)?
    let lan: LANHost?
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let sessionID: String
    let shareTitle: String
    let requesterIP: String?
}
