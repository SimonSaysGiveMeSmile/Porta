import Foundation

/// Matches the backend's `internal/share/share.go` File struct.
public struct ShareFile: Codable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let mime: String?

    public init(name: String, size: Int64, mime: String? = nil) {
        self.name = name
        self.size = size
        self.mime = mime
    }
}

/// Response from POST /v1/shares.
public struct CreatedShare: Codable {
    public let id: String
    public let token: String
    public let share_url: String
    public let expires_at: Date
    public let files: [ShareFile]
    public let title: String?
}

/// Response from /v1/sessions/:id/status.
public struct SessionStatus: Codable {
    public enum State: String, Codable {
        case pending, approved, rejected, closed
    }
    public let session_id: String
    public let status: State
}
