import XCTest
@testable import DeviceLookupForIntune

final class RunStateLookupTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func respond(_ url: URL, devices: [String], next: String? = nil) -> (HTTPURLResponse, Data) {
        let items = devices.map { #"{"id":"r-\#($0)","managedDevice":{"id":"\#($0)"}}"# }.joined(separator: ",")
        let link = next.map { #","@odata.nextLink":"\#($0)""# } ?? ""
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"value":[\#(items)]\#(link)}"#.utf8))
    }

    func testFilterHonouredReturnsOnlyThoseDevices() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in self.respond(request.url!, devices: ["d1"]) }
        let items = try await RunStateLookup.filtered(path: "/x", query: [], deviceIDs: ["d1"], client: GraphClient.mocked())
        XCTAssertEqual(items?.map(\.value.id), ["r-d1"])
        let url = try XCTUnwrap(MockURLProtocol.requests.first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "$filter" }?.value, "managedDevice/id eq 'd1'")
    }

    func testFilterIgnoredFallsBack() async throws {
        MockURLProtocol.handler = { request in self.respond(request.url!, devices: ["d1", "other"]) }
        let items = try await RunStateLookup.filtered(path: "/x", query: [], deviceIDs: ["d1"], client: GraphClient.mocked())
        XCTAssertNil(items)
    }

    func testRejectedFilterFallsBack() async throws {
        MockURLProtocol.script([(400, [:], #"{"error":{"message":"bad filter"}}"#)])
        let items = try await RunStateLookup.filtered(path: "/x", query: [], deviceIDs: ["d1"], client: GraphClient.mocked())
        XCTAssertNil(items)
    }

    func testTooManyOrUnsafeIDsSkipTheFilter() async throws {
        MockURLProtocol.requests = []
        let many = (0...RunStateLookup.maxDevices).map { "d\($0)" }
        let tooMany = try await RunStateLookup.filtered(path: "/x", query: [], deviceIDs: many, client: GraphClient.mocked())
        let unsafe = try await RunStateLookup.filtered(path: "/x", query: [], deviceIDs: ["a' or 'b"], client: GraphClient.mocked())
        XCTAssertNil(tooMany)
        XCTAssertNil(unsafe)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
}
