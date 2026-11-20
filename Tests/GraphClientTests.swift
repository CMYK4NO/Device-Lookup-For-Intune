import XCTest
@testable import DeviceLookupForIntune

final class DelayRecorder: @unchecked Sendable {
    var values: [TimeInterval] = []
}

final class GraphClientTests: XCTestCase {
    private let recorder = DelayRecorder()
    private var requests: [URLRequest] = []

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(maxRetries: Int = 4) -> GraphClient {
        let recorder = recorder
        return GraphClient(
            session: MockURLProtocol.session(),
            tokenProvider: { "tok" },
            maxRetries: maxRetries,
            sleep: { recorder.values.append($0) }
        )
    }

    /// Replies with the given (status, headers, body) in order; the last one repeats.
    private func script(_ responses: [(Int, [String: String], String)]) {
        var index = 0
        MockURLProtocol.handler = { [self] request in
            requests.append(request)
            let (status, headers, body) = responses[min(index, responses.count - 1)]
            index += 1
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
        }
    }

    private func expectError<T>(_ expected: GraphError, file: StaticString = #filePath, line: UInt = #line,
                                _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GraphError, expected, file: file, line: line)
        }
    }

    // MARK: URL, get

    func testURLBuildingKeepsODataSyntax() throws {
        let client = makeClient()
        let url = try client.url(path: "/deviceManagement/managedDevices", query: [
            URLQueryItem(name: "$filter", value: "userPrincipalName eq 'o''brien@x.com'"),
            URLQueryItem(name: "$select", value: "id,deviceName"),
        ])
        XCTAssertEqual(url.host, "graph.microsoft.com")
        XCTAssertEqual(url.path, "/beta/deviceManagement/managedDevices")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "$filter" }?.value, "userPrincipalName eq 'o''brien@x.com'")
        XCTAssertEqual(items?.first { $0.name == "$select" }?.value, "id,deviceName")
    }

    func testGetAttachesBearerTokenAndDecodes() async throws {
        script([(200, [:], #"{"id":"1","deviceName":"Mac"}"#)])
        let client = makeClient()
        let device = try await client.get(ManagedDevice.self, url: client.url(path: "/deviceManagement/managedDevices/1"))
        XCTAssertEqual(device.deviceName, "Mac")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://graph.microsoft.com/beta/deviceManagement/managedDevices/1")
    }

    // MARK: Paging

    func testCollectFollowsNextLinkAndReportsProgress() async throws {
        let next = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?$skiptoken=abc"
        script([
            (200, [:], #"{"@odata.nextLink":"\#(next)","value":[{"id":"a"},{"id":"b"}]}"#),
            (200, [:], #"{"value":[{"id":"c","deviceName":null}]}"#),
        ])
        var progress: [Int] = []
        let items = try await makeClient().collect(ManagedDevice.self, path: "/deviceManagement/managedDevices") { progress.append($0) }
        XCTAssertEqual(items.map(\.value.id), ["a", "b", "c"])
        XCTAssertEqual(progress, [2, 3])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.absoluteString, next)
        XCTAssertTrue(items[0].raw.contains("\"a\""))
    }

    func testRawJSONKeepsFieldsTheModelIgnores() async throws {
        script([(200, [:], #"{"value":[{"id":"r1","resultMessage":"hello","preRemediationDetectionScriptOutput":"win-value"}]}"#)])
        let items = try await makeClient().collect(RunState.self, path: "/x")
        XCTAssertTrue(items.first?.raw.contains("hello") == true)
        XCTAssertTrue(items.first?.raw.contains("win-value") == true)
    }

    func testForeignNextLinkIsRejectedBeforeAnyTokenIsSent() async {
        script([(200, [:], #"{"@odata.nextLink":"https://evil.example/steal","value":[]}"#)])
        let client = makeClient()
        await expectError(.invalidResponse) { try await client.collect(ManagedDevice.self, path: "/x") }
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: Retry

    func testRetryHonorsRetryAfterHeader() async throws {
        script([(429, ["Retry-After": "3"], "{}"), (200, [:], #"{"value":[]}"#)])
        _ = try await makeClient().collect(ManagedDevice.self, path: "/x")
        XCTAssertEqual(recorder.values, [3])
        XCTAssertEqual(requests.count, 2)
    }

    func testExponentialBackoffWithoutHeader() async throws {
        script([(503, [:], "{}"), (503, [:], "{}"), (200, [:], #"{"value":[]}"#)])
        _ = try await makeClient().collect(ManagedDevice.self, path: "/x")
        XCTAssertEqual(recorder.values, [1, 2])
    }

    func testGatewayTimeoutIsRetriedTwiceThenReported() async throws {
        script([(504, [:], "{}"), (504, [:], "{}"), (200, [:], #"{"value":[]}"#)])
        _ = try await makeClient().collect(ManagedDevice.self, path: "/x")
        XCTAssertEqual(requests.count, 3)

        script([(504, [:], "{}")])
        do {
            _ = try await makeClient().collect(ManagedDevice.self, path: "/x")
            XCTFail("expected an error")
        } catch GraphError.http(let status, _) {
            XCTAssertEqual(status, 504)
        }
    }

    func testGivesUpAfterMaxRetries() async {
        script([(429, [:], "{}")])
        let client = makeClient(maxRetries: 2)
        await expectError(.throttled) { try await client.collect(ManagedDevice.self, path: "/x") }
        XCTAssertEqual(recorder.values, [1, 2])
        XCTAssertEqual(requests.count, 3)
    }

    func testCancellationDuringBackoffPropagates() async {
        script([(429, [:], "{}")])
        let client = GraphClient(session: MockURLProtocol.session(), tokenProvider: { "tok" }, sleep: { _ in throw CancellationError() })
        do {
            _ = try await client.collect(ManagedDevice.self, path: "/x")
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(GraphClient.delay(attempt: 10, retryAfter: nil), 30)
        XCTAssertEqual(GraphClient.delay(attempt: 0, retryAfter: "9999"), 120)
    }

    // MARK: Error mapping

    func testStatusMapping() async {
        let client = makeClient()
        script([(401, [:], "{}")])
        await expectError(.unauthorized) { try await client.collect(ManagedDevice.self, path: "/x") }
        script([(403, [:], "{}")])
        await expectError(.forbidden(message: nil)) { try await client.collect(ManagedDevice.self, path: "/x") }
        script([(500, [:], #"{"error":{"code":"x","message":"boom"}}"#)])
        await expectError(.http(status: 500, message: "boom")) { try await client.collect(ManagedDevice.self, path: "/x") }
    }

    func testNetworkFailureMapped() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeClient().collect(ManagedDevice.self, path: "/x")
            XCTFail("expected error")
        } catch {
            guard case .network? = error as? GraphError else { return XCTFail("got \(error)") }
        }
    }

    func testMalformedCollectionIsInvalidResponse() async {
        script([(200, [:], #"{"nope":1}"#)])
        let client = makeClient()
        await expectError(.invalidResponse) { try await client.collect(ManagedDevice.self, path: "/x") }
    }
}

final class GraphForbiddenMessageTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testForbiddenCarriesGraphMessage() async {
        MockURLProtocol.script([(403, [:], #"{"error":{"code":"Forbidden","message":"Application is not authorized"}}"#)])
        do {
            _ = try await GraphClient.mocked().collect(ManagedDevice.self, path: "/x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GraphError, .forbidden(message: "Application is not authorized"))
            XCTAssertTrue(error.localizedDescription.contains("Graph says: Application is not authorized"))
        }
    }
}

final class GraphErrorMessageTests: XCTestCase {
    private func message(_ json: String) -> String? { GraphClient.message(from: Data(json.utf8)) }

    func testPlainMessage() {
        XCTAssertEqual(message(#"{"error":{"message":"boom"}}"#), "boom")
    }

    func testUnwrapsNestedIntuneJSONAndFlattensWhitespace() {
        let nested = #"{\"_version\":3,\"Message\":\"Not authorized\\r\\n for this operation\"}"#
        XCTAssertEqual(message(#"{"error":{"message":"\#(nested)"}}"#), "Not authorized for this operation")
    }

    func testMissingOrEmptyMessage() {
        XCTAssertNil(message(#"{"error":{}}"#))
        XCTAssertNil(message(#"{"error":{"message":"  "}}"#))
        XCTAssertNil(message("not json"))
    }
}

extension GraphClientTests {
    func testGetIsTheDefaultMethodAndPostSendsNoBody() async throws {
        MockURLProtocol.script([(204, [:], "")])
        let client = GraphClient.mocked()
        try await client.post(url: try client.url(path: "/deviceManagement/managedDevices/x/rotateLocalAdminPassword"))

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }
}
