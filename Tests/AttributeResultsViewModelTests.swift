import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class AttributeResultsViewModelTests: XCTestCase {
    private let script = ScriptSummary(id: "s1", displayName: "Battery", customAttributeName: "battery", lastModifiedDateTime: nil)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func runState(_ id: String, device: String, upn: String, state: String, value: String) -> String {
        #"{"id":"\#(id)","runState":"\#(state)","resultMessage":"\#(value)","lastStateUpdateDateTime":"2026-01-01T10:00:00Z","managedDevice":{"id":"d-\#(id)","deviceName":"\#(device)","userPrincipalName":"\#(upn)","serialNumber":"SN\#(id)","operatingSystem":"macOS","osVersion":"14"}}"#
    }

    private func loadedModel() async -> AttributeResultsViewModel {
        let next = "https://graph.microsoft.com/beta/next?skip=1"
        MockURLProtocol.script([
            (200, [:], #"{"@odata.nextLink":"\#(next)","value":[\#(runState("1", device: "Zed", upn: "z@x.com", state: "success", value: "88%")),\#(runState("2", device: "Alpha", upn: "a@x.com", state: "error", value: ""))]}"#),
            (200, [:], #"{"value":[\#(runState("3", device: "Mid", upn: "m@x.com", state: "success", value: "52%"))]}"#),
        ])
        let model = AttributeResultsViewModel(config: .macOS, script: script)
        await model.load(client: .mocked())
        return model
    }

    func testLoadBuildsRowsAcrossPages() async throws {
        let model = await loadedModel()
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.loadedCount, 3)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        let first = try XCTUnwrap(MockURLProtocol.requests.first?.url)
        XCTAssertEqual(first.path, "/beta/deviceManagement/deviceCustomAttributeShellScripts/s1/deviceRunStates")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testDefaultSortIsByDeviceAndCanBeReversed() async {
        let model = await loadedModel()
        XCTAssertEqual(model.filteredRows.map(\.device), ["Alpha", "Mid", "Zed"])
        model.sortOrder = [KeyPathComparator(\AttributeRow.device, order: .reverse)]
        XCTAssertEqual(model.filteredRows.map(\.device), ["Zed", "Mid", "Alpha"])
    }

    func testSearchMatchesAnyColumnCaseInsensitively() async {
        let model = await loadedModel()
        model.searchText = "M@X.COM"
        XCTAssertEqual(model.filteredRows.map(\.device), ["Mid"])
        model.searchText = "88%"
        XCTAssertEqual(model.filteredRows.map(\.device), ["Zed"])
        model.searchText = "nothing"
        XCTAssertTrue(model.filteredRows.isEmpty)
    }

    func testRunStateFilterAndOptions() async {
        let model = await loadedModel()
        XCTAssertEqual(model.runStates, ["error", "success"])
        model.runStateFilter = "success"
        XCTAssertEqual(model.filteredRows.map(\.device), ["Mid", "Zed"])
        model.searchText = "zed"
        XCTAssertEqual(model.filteredRows.map(\.device), ["Zed"])
    }

    func testForbiddenShowsMessageAndNoRows() async {
        MockURLProtocol.script([(403, [:], "{}")])
        let model = AttributeResultsViewModel(config: .macOS, script: script)
        await model.load(client: .mocked())
        XCTAssertEqual(model.errorMessage, GraphError.forbidden(message: nil).errorDescription)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testMissingSerialAndOSAreFilledFromDeviceInventory() async {
        MockURLProtocol.handler = { request in
            let url = request.url!
            let body = url.path.hasSuffix("/managedDevices")
                ? #"{"value":[{"id":"d1","serialNumber":"C02XYZ","operatingSystem":"macOS"}]}"#
                : #"{"value":[{"id":"1","runState":"success","resultMessage":"ok","managedDevice":{"id":"d1","deviceName":"Mac"}}]}"#
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = AttributeResultsViewModel(config: .macOS, script: script)
        await model.load(client: .mocked())
        XCTAssertEqual(model.rows.first?.serial, "C02XYZ")
        XCTAssertEqual(model.operatingSystem(of: model.rows[0]), "macOS")
    }
}

extension AttributeResultsViewModelTests {
    /// The device list is read while the statuses page in, so responses are routed by path, not by order.
    private func route(status: String, devices: String, rejectTop: Bool = false) {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let url = request.url!
            let (code, body): (Int, String)
            if url.path.hasSuffix("/managedDevices") {
                (code, body) = (200, devices)
            } else if rejectTop, url.query?.contains("top") == true {
                (code, body) = (400, #"{"error":{"message":"bad top"}}"#)
            } else {
                (code, body) = (200, status)
            }
            return (HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    func testStatusSourcesKeepOnlyDevicesOfTheirOS() async {
        route(
            status: #"{"value":[{"id":"1","deviceDisplayName":"Mac","status":"compliant"},{"id":"2","deviceDisplayName":"PC","status":"notApplicable"},{"id":"3","deviceDisplayName":"OldMac","status":"notApplicable"}]}"#,
            devices: #"{"value":[{"id":"a","deviceName":"mac","serialNumber":"S1","osVersion":"14.5","operatingSystem":"macOS"},{"id":"b","deviceName":"PC","operatingSystem":"Windows"},{"id":"c","deviceName":"OldMac","operatingSystem":"macOS"}]}"#
        )
        let model = AttributeResultsViewModel(config: OSSourceConfig.complianceSources[0], script: script)
        await model.load(client: .mocked())
        XCTAssertEqual(model.rows.map(\.device), ["Mac", "OldMac"])
        XCTAssertEqual(model.rows.map(\.serial), ["S1", ""])
        XCTAssertEqual(model.rows.map(\.osVersion), ["14.5", ""])
    }
}

extension AttributeResultsViewModelTests {
    func testSharedInventoryIsReadOnce() async throws {
        MockURLProtocol.script([(200, [:], #"{"value":[{"id":"a","deviceName":"Mac","serialNumber":"S","operatingSystem":"macOS"}]}"#)])
        let inventory = DeviceInventory()
        let first = try await inventory.devices(client: .mocked())
        let second = try await inventory.devices(client: .mocked())
        XCTAssertEqual(first, second)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        await inventory.reset()
        _ = try await inventory.devices(client: .mocked())
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }
}

extension AttributeResultsViewModelTests {
    func testTopIsDroppedWhenIntuneRejectsIt() async {
        route(
            status: #"{"value":[{"id":"1","deviceDisplayName":"Mac","status":"compliant"}]}"#,
            devices: #"{"value":[{"id":"a","deviceName":"Mac","operatingSystem":"macOS"}]}"#,
            rejectTop: true
        )
        let model = AttributeResultsViewModel(config: OSSourceConfig.complianceSources[0], script: script)
        await model.load(client: .mocked())
        XCTAssertEqual(model.rows.map(\.device), ["Mac"])
        // Compliance asks for nothing but `$top`, so the retry has no query string at all.
        let statusURLs = MockURLProtocol.requests.compactMap(\.url).filter { !$0.path.hasSuffix("/managedDevices") }
        XCTAssertEqual(statusURLs.count, 2)
        XCTAssertEqual(statusURLs.first?.query?.contains("top"), true)
        XCTAssertFalse(statusURLs.last?.query?.contains("top") ?? false)
    }
}

extension AttributeResultsViewModelTests {
    func testDuplicateStatusIDsAreDroppedKeepingTheFirst() async {
        MockURLProtocol.script([(200, [:], #"{"value":[\#(runState("1", device: "Zed", upn: "z@x.com", state: "success", value: "a")),\#(runState("1", device: "Zed", upn: "z@x.com", state: "error", value: "b")),\#(runState("2", device: "Alpha", upn: "a@x.com", state: "success", value: "c"))]}"#)])
        let model = AttributeResultsViewModel(config: .macOS, script: script)
        await model.load(client: .mocked())
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows.first { $0.device == "Zed" }?.value, "a")
        XCTAssertEqual(Set(model.rows.map(\.id)).count, model.rows.count)
    }
}

extension AttributeResultsViewModelTests {
    func testRowsKeptByASearchGetSerialsFromTheDeviceList() async throws {
        MockURLProtocol.script([(200, [:], #"{"value":[{"id":"d1","serialNumber":"C02XYZ","operatingSystem":"macOS"},{"id":"d2","serialNumber":"OTHER"}]}"#)])
        let json = #"{"id":"1","runState":"success","resultMessage":"ok","managedDevice":{"id":"d1","deviceName":"Mac"}}"#
        let item = GraphItem(value: try JSONDecoder().decode(RunState.self, from: Data(json.utf8)), raw: json)
        let cache = ResultsCache()
        let key = ResultsCache.key(config: .macOS, script: script)
        cache.store(key, CachedResults(items: [item], rows: [AttributeRow(item: item, config: .macOS)], inventory: [:], loadedAt: Date()))

        let model = AttributeResultsViewModel(config: .macOS, script: script, cache: cache)
        await model.load(client: .mocked())
        XCTAssertEqual(model.rows.first?.serial, "C02XYZ")
        XCTAssertEqual(MockURLProtocol.requests.compactMap { $0.url?.path }, ["/beta/deviceManagement/managedDevices"])
        XCTAssertEqual(Array(try XCTUnwrap(cache.entry(key)).inventory.keys), ["d1"])
    }
}
