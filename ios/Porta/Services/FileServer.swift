import Foundation
import PortaCore

/// FileServer answers inbound tunnel requests by reading local files.
///
/// The app hands it a map of share filename → local URL when a share is
/// created. Incoming `GET /files/<name>` requests stream that file back.
/// Range requests are honored (HTTP 206) so Safari's download manager can
/// resume interrupted downloads.
public final class FileServer: TunnelResponder {
    private let files: [String: URL]
    private let chunkSize: Int

    public init(files: [String: URL], chunkSize: Int = 256 * 1024) {
        self.files = files
        self.chunkSize = chunkSize
    }

    public func handle(
        method: String,
        path: String,
        writer: TunnelResponseWriter
    ) async throws {
        guard method == "GET" || method == "HEAD" else {
            try await writer.writeHead(status: 405, headers: ["Allow": "GET, HEAD"])
            return
        }

        guard let name = extractFilename(from: path),
              let url = files[name] else {
            try await writer.writeHead(status: 404, headers: ["Content-Type": "text/plain"])
            await writer.writeChunk(Data("not found".utf8))
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        if method == "HEAD" {
            try await writer.writeHead(status: 200, headers: baseHeaders(name: name, size: size))
            return
        }

        // For MVP we ignore Range (no headers forwarded from edge yet).
        // The edge can be extended to pass them through OpenHeader.headers.
        try await writer.writeHead(status: 200, headers: baseHeaders(name: name, size: size))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            await writer.writeChunk(chunk)
        }
    }

    private func extractFilename(from path: String) -> String? {
        // Expected: /files/<url-encoded-name>
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "files" else { return nil }
        return parts[1].removingPercentEncoding
    }

    private func baseHeaders(name: String, size: Int64) -> [String: String] {
        [
            "Content-Type": mimeType(for: name),
            "Content-Length": String(size),
            "Content-Disposition": "attachment; filename=\"\(name)\"",
            "Cache-Control": "no-store",
        ]
    }

    private func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "pdf":         return "application/pdf"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "zip":         return "application/zip"
        default:            return "application/octet-stream"
        }
    }
}
