import Foundation

/// Typed client for the Porta backend. URLSession-based so it runs in both
/// the app and the share extension.
public actor PortaAPI {
    public let baseURL: URL
    private var jwt: String?
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func setJWT(_ token: String?) { self.jwt = token }
    public func currentJWT() -> String? { jwt }

    // MARK: - Auth

    public struct Nonce: Decodable { public let nonce: String }
    public struct VerifyReq: Encodable {
        public let public_key: String
        public let nonce: String
        public let signature: String
        public let apns_token: String?
        public let platform: String
    }
    public struct VerifyResp: Decodable {
        public let device_id: String
        public let jwt: String
    }

    public func nonce() async throws -> Nonce {
        try await post("/v1/auth/nonce", body: EmptyBody())
    }

    public func verify(publicKey: Data, nonce: String, signature: Data, apns: String?) async throws -> VerifyResp {
        let body = VerifyReq(
            public_key: publicKey.base64URL,
            nonce: nonce,
            signature: signature.base64URL,
            apns_token: apns,
            platform: "ios"
        )
        return try await post("/v1/auth/verify", body: body)
    }

    // MARK: - Shares

    public struct CreateShareReq: Encodable {
        public let title: String?
        public let files: [ShareFile]
    }

    public func createShare(title: String?, files: [ShareFile]) async throws -> CreatedShare {
        try await post("/v1/shares", body: CreateShareReq(title: title, files: files))
    }

    public func approve(sessionID: String) async throws {
        _ = try await postRaw("/v1/sessions/\(sessionID)/approve", body: EmptyBody())
    }

    public func reject(sessionID: String) async throws {
        _ = try await postRaw("/v1/sessions/\(sessionID)/reject", body: EmptyBody())
    }

    // MARK: - Internals

    private struct EmptyBody: Encodable {}

    private func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        let data = try await postRaw(path, body: body)
        return try JSONDecoder.porta.decode(R.self, from: data)
    }

    private func postRaw<B: Encodable>(_ path: String, body: B) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        if !(body is EmptyBody) {
            req.httpBody = try JSONEncoder.porta.encode(body)
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PortaError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1, data)
        }
        return data
    }
}

public enum PortaError: Error {
    case badStatus(Int, Data)
}

extension Data {
    /// Base64URL (unpadded) — matches the Go backend's `base64.RawURLEncoding`.
    public var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public init?(base64URL s: String) {
        var padded = s.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        let rem = padded.count % 4
        if rem > 0 { padded.append(String(repeating: "=", count: 4 - rem)) }
        self.init(base64Encoded: padded)
    }
}

extension JSONEncoder {
    static var porta: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
extension JSONDecoder {
    static var porta: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
