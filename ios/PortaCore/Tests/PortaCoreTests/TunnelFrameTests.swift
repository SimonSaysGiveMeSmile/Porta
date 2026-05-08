import XCTest
@testable import PortaCore

final class TunnelFrameTests: XCTestCase {
    func testEncodeDecodeRoundtrip() {
        let id = Data(count: 16).enumerated().reduce(into: Data()) { acc, pair in
            acc.append(UInt8(pair.offset))
        }
        let payload = "hello".data(using: .utf8)!
        let frame = TunnelFrame(op: .body, requestID: id, payload: payload)
        let encoded = frame.encode()
        let back = TunnelFrame.decode(encoded)
        XCTAssertNotNil(back)
        XCTAssertEqual(back?.op, .body)
        XCTAssertEqual(back?.requestID, id)
        XCTAssertEqual(back?.payload, payload)
    }

    func testDecodeRejectsShortFrames() {
        XCTAssertNil(TunnelFrame.decode(Data([0x01])))
        XCTAssertNil(TunnelFrame.decode(Data(count: 16)))
    }

    func testOpenHeaderJSONMatchesGoShape() throws {
        let h = OpenHeader(method: "GET", path: "/files/a.txt",
                           headers: ["User-Agent": ["Mozilla"]])
        let data = try JSONEncoder().encode(h)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["method"] as? String, "GET")
        XCTAssertEqual(obj["path"] as? String, "/files/a.txt")
    }
}

final class Base64URLTests: XCTestCase {
    func testRoundtrip() {
        let bytes = Data([0, 1, 2, 3, 0xff, 0xfe, 0x10])
        let s = bytes.base64URL
        XCTAssertFalse(s.contains("="))
        XCTAssertFalse(s.contains("+"))
        XCTAssertFalse(s.contains("/"))
        XCTAssertEqual(Data(base64URL: s), bytes)
    }
}
