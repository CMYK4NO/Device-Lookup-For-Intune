import XCTest
@testable import DeviceLookupForIntune

final class LoopbackRequestParserTests: XCTestCase {
    private func request(_ line: String) -> Data { Data("\(line)\r\nHost: localhost\r\n\r\n".utf8) }

    func testParsesCodeAndState() throws {
        let items = try XCTUnwrap(LoopbackRequestParser.queryItems(fromRequest: request("GET /?code=a%20b&state=xyz HTTP/1.1")))
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "a b")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "xyz")
    }

    func testParsesErrorRedirect() throws {
        let items = try XCTUnwrap(LoopbackRequestParser.queryItems(fromRequest: request("GET /?error=access_denied&state=s HTTP/1.1")))
        XCTAssertEqual(items.first { $0.name == "error" }?.value, "access_denied")
    }

    func testIgnoresOtherRequests() {
        XCTAssertNil(LoopbackRequestParser.queryItems(fromRequest: request("GET /favicon.ico HTTP/1.1")))
        XCTAssertNil(LoopbackRequestParser.queryItems(fromRequest: request("GET /?code=only HTTP/1.1")))
        XCTAssertNil(LoopbackRequestParser.queryItems(fromRequest: request("POST /?state=s HTTP/1.1")))
        XCTAssertNil(LoopbackRequestParser.queryItems(fromRequest: Data()))
    }
}
