import Foundation

/// Mirrors `internal/tunnel/frame.go`. One byte opcode + 16-byte request ID +
/// raw payload. Keep in sync with the backend by hand — a mismatched byte
/// here silently breaks all transfers.
public enum TunnelOp: UInt8 {
    case open   = 0x01 // edge → sender: begin request, JSON header
    case head   = 0x02 // sender → edge: response head, JSON
    case body   = 0x03 // bidi: body chunk, raw bytes
    case end    = 0x04 // bidi: stream complete
    case err    = 0x05 // sender → edge: utf-8 error message
    case cancel = 0x06 // edge → sender: receiver disconnected
}

public struct TunnelFrame {
    public let op: TunnelOp
    public let requestID: Data   // 16 bytes
    public let payload: Data

    public init(op: TunnelOp, requestID: Data, payload: Data = .init()) {
        precondition(requestID.count == 16, "requestID must be 16 bytes")
        self.op = op
        self.requestID = requestID
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: 17 + payload.count)
        out.append(op.rawValue)
        out.append(requestID)
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) -> TunnelFrame? {
        guard data.count >= 17, let op = TunnelOp(rawValue: data[data.startIndex]) else {
            return nil
        }
        let idStart = data.index(data.startIndex, offsetBy: 1)
        let idEnd = data.index(idStart, offsetBy: 16)
        let id = data[idStart..<idEnd]
        let body = data[idEnd...]
        return TunnelFrame(op: op, requestID: Data(id), payload: Data(body))
    }
}

public struct OpenHeader: Codable {
    public let method: String
    public let path: String
    public let headers: [String: [String]]?
    public init(method: String, path: String, headers: [String: [String]]? = nil) {
        self.method = method; self.path = path; self.headers = headers
    }
}

public struct HeadMessage: Codable {
    public let status: Int
    public let headers: [String: [String]]?
    public init(status: Int, headers: [String: [String]]? = nil) {
        self.status = status; self.headers = headers
    }
}
