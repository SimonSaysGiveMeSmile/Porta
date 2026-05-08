#if canImport(Network)
import XCTest
import Network
@testable import PortaCore

final class LANHostTests: XCTestCase {
    /// Spin up a LANHost serving one file, connect via raw TCP, and verify
    /// the manifest endpoint returns the share. Keeps the test hermetic —
    /// no Bonjour discovery needed — by connecting directly to the bound port.
    func testManifestEndpoint() async throws {
        let file = ShareFile(name: "hello.txt", size: 5)
        let manifest = LANHost.ShareManifest(title: "t", files: [file])

        let responder = StubResponder()
        let host = LANHost(manifest: manifest, responder: responder)
        try host.start()
        defer { host.stop() }

        // Wait up to 2s for the listener to assign a port.
        let port = try await waitForPort(host, timeoutMs: 2000)

        let response = try await get(host: "127.0.0.1", port: port, path: "/share")
        XCTAssertTrue(response.contains("200"))
        XCTAssertTrue(response.contains("hello.txt"))
    }

    /// The root path serves a self-contained HTML landing page listing the
    /// shared files so a receiver can just open the URL in any browser —
    /// the "no backend required" path.
    func testLandingPageServesHTMLWithFileLinks() async throws {
        let files = [
            ShareFile(name: "report.pdf", size: 1234),
            ShareFile(name: "photo.jpg", size: 567_890),
        ]
        let manifest = LANHost.ShareManifest(title: "Meeting notes", files: files)

        let host = LANHost(manifest: manifest, responder: StubResponder())
        try host.start()
        defer { host.stop() }

        let port = try await waitForPort(host, timeoutMs: 2000)
        let response = try await get(host: "127.0.0.1", port: port, path: "/")

        XCTAssertTrue(response.contains("HTTP/1.1 200"))
        XCTAssertTrue(response.lowercased().contains("text/html"))
        XCTAssertTrue(response.contains("Meeting notes"))
        XCTAssertTrue(response.contains("/files/report.pdf"))
        XCTAssertTrue(response.contains("/files/photo.jpg"))
        XCTAssertTrue(response.contains("2 files"))
    }

    // MARK: - helpers

    private func waitForPort(_ host: LANHost, timeoutMs: Int) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if host.port != 0 { return host.port }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "test", code: 1)
    }

    private func get(host: String, port: UInt16, path: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(rawValue: port)!,
                                    using: .tcp)
            let q = DispatchQueue(label: "test.conn")
            var accum = Data()
            var resumed = false
            func complete(_ result: Result<String, Error>) {
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            func readMore() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { d, _, done, err in
                    if let d { accum.append(d) }
                    if let err { complete(.failure(err)); return }
                    if done {
                        complete(.success(String(decoding: accum, as: UTF8.self)))
                        return
                    }
                    readMore()
                }
            }
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    let req = "GET \(path) HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in readMore() })
                }
                if case .failed(let err) = state { complete(.failure(err)) }
            }
            conn.start(queue: q)
        }
    }
}

private final class StubResponder: TunnelResponder {
    func handle(method: String, path: String, writer: TunnelResponseWriter) async throws {
        try await writer.writeHead(status: 200, headers: ["Content-Type": "text/plain"])
        await writer.writeChunk(Data("hello".utf8))
    }
}
#endif
