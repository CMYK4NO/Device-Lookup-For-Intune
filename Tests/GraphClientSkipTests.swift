import XCTest
@testable import DeviceLookupForIntune

final class GraphClientSkipTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func item(_ id: Int) -> String { #"{"id":"\#(id)"}"# }

    func testSkipPagedListsAreReadSeveralPagesAtOnceInOrder() async throws {
        // 5 items, pages of 2: skip 0 -> 1,2 (next skip=2), skip 2 -> 3,4, skip 4 -> 5, skip 6 -> empty.
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let url = request.url!
            let skip = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$skip" }?.value.flatMap(Int.init) ?? 0
            let ids = skip < 5 ? Array(skip + 1...min(5, skip + 2)) : []
            let items = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
            let next = skip + 2 < 5 ? #","@odata.nextLink":"https://graph.microsoft.com/beta/x?$skip=\#(skip + 2)""# : ""
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"value":[\#(items)]\#(next)}"#.utf8))
        }
        let all = try await GraphClient.mocked().collectBySkip(RunState.self, path: "/x", maxInFlight: 2)
        XCTAssertEqual(all.map(\.value.id), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(MockURLProtocol.requests.count, 3) // first page, then skip 2 and 4 together
    }

    func testOtherNextLinksAreFollowedOneByOne() async throws {
        MockURLProtocol.script([
            (200, [:], #"{"@odata.nextLink":"https://graph.microsoft.com/beta/x?$skiptoken=abc","value":[\#(item(1))]}"#),
            (200, [:], #"{"value":[\#(item(2))]}"#),
        ])
        let all = try await GraphClient.mocked().collectBySkip(RunState.self, path: "/x")
        XCTAssertEqual(all.map(\.value.id), ["1", "2"])
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }
}

extension GraphClientSkipTests {
    private func respond(_ url: URL, ids: [Int], next: String?) -> (HTTPURLResponse, Data) {
        let items = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        let link = next.map { #","@odata.nextLink":"\#($0)""# } ?? ""
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"value":[\#(items)]\#(link)}"#.utf8))
    }

    func testTokenLinksSwitchToSkipWhenSkipIsHonoured() async throws {
        // 5 items in pages of 2 with $skiptoken links; the server also honours $skip.
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let url = request.url!
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let skip = queryItems.first { $0.name == "$skip" }?.value.flatMap(Int.init)
                ?? (queryItems.contains { $0.name == "$skiptoken" } ? 2 : 0)
            let ids = skip < 5 ? Array(skip + 1...min(5, skip + 2)) : []
            return self.respond(url, ids: ids, next: skip + 2 < 5 ? "https://graph.microsoft.com/beta/x?$skiptoken=t" : nil)
        }
        let all = try await GraphClient.mocked().collectBySkip(RunState.self, path: "/x", maxInFlight: 2)
        XCTAssertEqual(all.map(\.value.id), ["1", "2", "3", "4", "5"])
    }

    func testTokenLinksStaySequentialWhenSkipIsIgnored() async throws {
        // The server ignores $skip: it always answers from the token, so the probe does not match the second page.
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let url = request.url!
            let hasToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "$skiptoken" } ?? false
            let tokenValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$skiptoken" }?.value
            switch (hasToken, tokenValue) {
            case (true, "a"): return self.respond(url, ids: [3, 4], next: "https://graph.microsoft.com/beta/x?$skiptoken=b")
            case (true, "b"): return self.respond(url, ids: [5], next: nil)
            default: return self.respond(url, ids: [1, 2], next: "https://graph.microsoft.com/beta/x?$skiptoken=a")
            }
        }
        let all = try await GraphClient.mocked().collectBySkip(RunState.self, path: "/x", maxInFlight: 2)
        XCTAssertEqual(all.map(\.value.id), ["1", "2", "3", "4", "5"])
    }
}
