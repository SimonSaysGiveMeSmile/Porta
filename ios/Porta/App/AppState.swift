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

@MainActor
final class AppState: ObservableObject {
    @Published var identity: DeviceIdentity?
    @Published var deviceID: String?
    @Published var activeShare: ActiveShare?
    @Published var pendingApprovals: [PendingApproval] = []
    @Published var recentShares: [CreatedShare] = []
    @Published var errorMessage: String?
    @Published var connection: ConnectionState = .unknown
    @Published var backendURLString: String {
        didSet {
            UserDefaults.standard.set(backendURLString, forKey: Self.backendKey)
            rebuildAPI()
        }
    }

    private(set) var api: PortaAPI
    var baseURL: URL { URL(string: backendURLString) ?? Self.defaultBackend }

    static let backendKey = "porta.backendURL"
    static let defaultBackend = URL(string: "http://localhost:8080")!

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.backendKey)
            ?? Self.defaultBackend.absoluteString
        self.backendURLString = saved
        self.api = PortaAPI(baseURL: URL(string: saved) ?? Self.defaultBackend)
        self.identity = DeviceIdentity.loadOrCreate()
    }

    private func rebuildAPI() {
        self.api = PortaAPI(baseURL: baseURL)
        self.deviceID = nil
        self.connection = .unknown
    }

    /// Attempt to reach the backend and authenticate. Safe to call repeatedly;
    /// a failure only sets `connection = .offline`, the app stays usable.
    func connect() async {
        guard let ident = identity else {
            connection = .offline(reason: "no identity")
            return
        }
        connection = .connecting
        do {
            let nonce = try await api.nonce()
            guard let nonceBytes = Data(base64URL: nonce.nonce) else {
                connection = .offline(reason: "bad nonce")
                return
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
            case NSURLErrorTimedOut:
                return "server timed out"
            case NSURLErrorNotConnectedToInternet:
                return "no internet"
            default:
                return "network error"
            }
        }
        return error.localizedDescription
    }

    func createShare(from urls: [URL], title: String?) async {
        if !connection.isOnline { await connect() }
        guard connection.isOnline else {
            errorMessage = "Server is offline. Check Settings and try again."
            return
        }
        do {
            let files: [ShareFile] = urls.compactMap {
                let size = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? 0
                return ShareFile(name: $0.lastPathComponent, size: size)
            }
            let share = try await api.createShare(title: title, files: files)
            let responder = FileServer(files: Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, $0) }))
            let client = TunnelClient(
                baseURL: baseURL,
                shareID: share.id,
                jwt: await api.currentJWT() ?? "",
                responder: responder
            )
            client.start()
            self.activeShare = ActiveShare(share: share, tunnel: client)
            self.recentShares.insert(share, at: 0)
        } catch {
            errorMessage = "Create failed: \(friendly(error))"
        }
    }

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

struct ActiveShare: Identifiable {
    let id = UUID()
    let share: CreatedShare
    let tunnel: TunnelClient
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let sessionID: String
    let shareTitle: String
    let requesterIP: String?
}
