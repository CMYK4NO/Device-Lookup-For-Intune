import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class ScriptCatalogViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testLoadSortsByTitleAndLooksUpScripts() async {
        MockURLProtocol.script([(200, [:], #"{"value":[{"id":"2","displayName":"beta"},{"id":"1","displayName":"Alpha","lastModifiedDateTime":"2026-01-01T00:00:00Z"}]}"#)])
        let catalog = ScriptCatalogViewModel()
        await catalog.loadIfNeeded(.macOS, client: .mocked())
        let listing = catalog.listing(for: .macOS)
        XCTAssertEqual(listing.scripts.map(\.id), ["1", "2"])
        XCTAssertTrue(listing.hasLoaded)
        XCTAssertNotNil(catalog.script(osID: "macOS", scriptID: "1")?.lastModified)
        XCTAssertNil(catalog.script(osID: "macOS", scriptID: "nope"))
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/beta/deviceManagement/deviceCustomAttributeShellScripts")
    }

    func testLoadIfNeededDoesNotRefetch() async {
        MockURLProtocol.script([(200, [:], #"{"value":[]}"#)])
        let catalog = ScriptCatalogViewModel()
        await catalog.loadIfNeeded(.macOS, client: .mocked())
        await catalog.loadIfNeeded(.macOS, client: .mocked())
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testErrorIsReportedAndRetryable() async {
        MockURLProtocol.script([(403, [:], "{}")])
        let catalog = ScriptCatalogViewModel()
        await catalog.loadIfNeeded(.macOS, client: .mocked())
        XCTAssertEqual(catalog.listing(for: .macOS).errorMessage, GraphError.forbidden(message: nil).errorDescription)
        XCTAssertFalse(catalog.listing(for: .macOS).hasLoaded)

        MockURLProtocol.script([(200, [:], #"{"value":[{"id":"1"}]}"#)])
        await catalog.loadIfNeeded(.macOS, client: .mocked())
        XCTAssertEqual(catalog.listing(for: .macOS).scripts.count, 1)
        XCTAssertNil(catalog.listing(for: .macOS).errorMessage)
    }

    func testOSesOfOneEndpointShareOneRequestAndSplitTheList() async {
        // macOS and Windows share one list; Linux policies are settings catalog policies with a list of their own.
        let legacy = ##"{"value":[{"id":"1","displayName":"Mac","@odata.type":"#microsoft.graph.macOSCompliancePolicy"},{"id":"2","displayName":"Win","@odata.type":"#microsoft.graph.windows10CompliancePolicy"},{"id":"3","displayName":"Phone","@odata.type":"#microsoft.graph.iosCompliancePolicy"}]}"##
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let body = request.url!.path.hasSuffix("/deviceCompliancePolicies") ? legacy : #"{"value":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let catalog = ScriptCatalogViewModel()
        let sources = OSSourceConfig.complianceSources
        for source in sources { await catalog.loadIfNeeded(source, client: .mocked()) }
        let paths = MockURLProtocol.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths.sorted(), ["/beta/deviceManagement/compliancePolicies", "/beta/deviceManagement/deviceCompliancePolicies"])
        XCTAssertEqual(catalog.listing(for: sources[0]).scripts.map(\.id), ["1"])
        XCTAssertEqual(catalog.listing(for: sources[1]).scripts.map(\.id), ["2"])
        XCTAssertTrue(catalog.listing(for: sources[2]).scripts.isEmpty)
        XCTAssertEqual(catalog.script(osID: sources[1].id, scriptID: "2")?.title, "Win")
        XCTAssertNil(catalog.script(osID: sources[0].id, scriptID: "2"))
    }

    func testPrefetchReadsEachEndpointOnceAndSkipsApps() async {
        MockURLProtocol.script([(200, [:], #"{"value":[]}"#)])
        let catalog = ScriptCatalogViewModel()
        await catalog.prefetch(client: .mocked())
        // Three script lists, compliance (macOS and Windows; Linux) and configurations.
        let paths = MockURLProtocol.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths.count, 6)
        XCTAssertEqual(Set(paths).count, 6)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/mobileApps") })
        XCTAssertTrue(catalog.listing(for: OSSourceConfig.complianceSources[0]).hasLoaded)
        XCTAssertFalse(catalog.listing(for: OSSourceConfig.appSources[0]).hasLoaded)
    }

    func testResetClearsListings() async {
        MockURLProtocol.script([(200, [:], #"{"value":[{"id":"1"}]}"#)])
        let catalog = ScriptCatalogViewModel()
        await catalog.loadIfNeeded(.macOS, client: .mocked())
        catalog.reset()
        XCTAssertFalse(catalog.listing(for: .macOS).hasLoaded)
    }
}
