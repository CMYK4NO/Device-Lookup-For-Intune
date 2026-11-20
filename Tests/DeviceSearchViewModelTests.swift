import XCTest
@testable import DeviceLookupForIntune

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func add(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

@MainActor
final class DeviceSearchViewModelTests: XCTestCase {
    private let devicesJSON = """
    {"value":[
      {"id":"d1","deviceName":"Mac1","serialNumber":"S1","operatingSystem":"macOS","osVersion":"14"},
      {"id":"d2","deviceName":"Mac2","serialNumber":"S2","operatingSystem":"macOS","osVersion":"15"}]}
    """
    private let scriptsJSON = #"{"value":[{"id":"s1","displayName":"Battery"},{"id":"s2","displayName":"Model"}]}"#

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func runState(_ id: String, device: String, value: String) -> String {
        #"{"id":"\#(id)","runState":"success","resultMessage":"\#(value)","managedDevice":{"id":"\#(device)","deviceName":"x"}}"#
    }

    /// Routes managed devices, the script list and per-script run states; unknown scripts get an empty page.
    private func route(devices: String? = nil, runStates: [String: (Int, String)]) -> RequestLog {
        let log = RequestLog()
        let devices = devices ?? devicesJSON
        let scripts = scriptsJSON
        MockURLProtocol.handler = { request in
            let url = request.url!
            log.add(url)
            func reply(_ status: Int, _ body: String) -> (HTTPURLResponse, Data) {
                (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            if url.path.hasSuffix("/managedDevices") { return reply(200, devices) }
            if url.path.hasSuffix("/deviceRunStates") {
                let scriptID = url.pathComponents[url.pathComponents.count - 2]
                let (status, body) = runStates[scriptID] ?? (200, #"{"value":[]}"#)
                return reply(status, body)
            }
            if url.path.hasSuffix("/deviceHealthScripts") { return reply(200, #"{"value":[{"id":"h1","displayName":"Health"}]}"#) }
            return reply(200, url.path.hasSuffix("/deviceCustomAttributeShellScripts") ? scripts : #"{"value":[]}"#)
        }
        return log
    }

    /// Walks the three steps: select every device, list their attributes, tick them all, read.
    private func readEverything(_ model: DeviceSearchViewModel) async {
        model.selection = Set(model.devices.map(\.id))
        await model.loadAttributes(client: .mocked())
        model.selectAllAttributes()
        await model.readAttributes(client: .mocked())
    }

    private func page(_ items: String...) -> (Int, String) { (200, #"{"value":[\#(items.joined(separator: ","))]}"#) }

    private func searched(_ upn: String = "a@x.com", runStates: [String: (Int, String)], devices: String? = nil) async -> (DeviceSearchViewModel, RequestLog) {
        let log = route(devices: devices, runStates: runStates)
        let model = DeviceSearchViewModel()
        model.query = upn
        await model.search(client: .mocked())
        await readEverything(model)
        return (model, log)
    }

    func testKeepsOnlyRunStatesOfTheUsersDevices() async throws {
        let (model, log) = await searched(runStates: [
            "s1": page(runState("r1", device: "d1", value: "88%"), runState("r2", device: "someone-else", value: "99%")),
            "s2": page(runState("r3", device: "d2", value: "MacBookPro")),
        ])
        XCTAssertEqual(model.rows.map(\.deviceName), ["Mac1", "Mac2"])
        XCTAssertEqual(model.rows.map(\.attribute), ["Battery", "Model"])
        XCTAssertEqual(model.rows.map(\.value), ["88%", "MacBookPro"])
        XCTAssertEqual(model.rows.map(\.serial), ["S1", "S2"])
        XCTAssertFalse(model.rows.contains { $0.value == "99%" })
        XCTAssertEqual(model.completedJobs, 2)
        XCTAssertNil(model.errorMessage)

        let first = try XCTUnwrap(log.urls.first)
        let filter = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }
        XCTAssertEqual(filter?.value, "userPrincipalName eq 'a@x.com'")
    }

    func testRunStatesWithoutDeviceAreIgnored() async {
        let (model, _) = await searched(runStates: [
            "s1": page(#"{"id":"r1","resultMessage":"orphan","managedDevice":null}"#, #"{"id":"r2","resultMessage":"nodevice"}"#),
        ])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.emptyResultsMessage, "The selected devices have not reported any custom attribute results.")
    }

    func testNoDevicesFoundStopsBeforeReadingAttributes() async {
        let (model, log) = await searched(runStates: [:], devices: #"{"value":[]}"#)
        XCTAssertEqual(model.infoMessage, "No devices found for a@x.com.")
        XCTAssertEqual(log.urls.count, 1)
        XCTAssertNil(model.emptyResultsMessage)
    }

    func testInvalidUPNMakesNoRequests() async {
        let (model, log) = await searched("not-a-upn", runStates: [:])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(log.urls.isEmpty)
        XCTAssertFalse(model.hasSearched)
    }

    func testOSFilterMessages() async {
        let (model, _) = await searched(runStates: ["s1": page(runState("r1", device: "d1", value: "v"))])
        XCTAssertEqual(model.visibleRows.count, 1)
        model.osFilter = "macOS"
        XCTAssertEqual(model.visibleRows.count, 1)
        model.osFilter = "windows"
        XCTAssertTrue(model.visibleRows.isEmpty)
        XCTAssertEqual(model.emptyResultsMessage, "None of the selected devices is a Windows device.")

        let windowsOnly = #"{"value":[{"id":"d1","deviceName":"PC","operatingSystem":"Windows"}]}"#
        let (other, _) = await searched(runStates: [:], devices: windowsOnly)
        other.osFilter = "macOS"
        XCTAssertEqual(other.emptyResultsMessage, "None of the selected devices is a macOS device.")
    }

    func testFailedAttributeBecomesWarningAndOthersSurvive() async {
        let (model, _) = await searched(runStates: [
            "s1": page(runState("r1", device: "d1", value: "ok")),
            "s2": (500, #"{"error":{"message":"boom"}}"#),
        ])
        XCTAssertEqual(model.rows.map(\.value), ["ok"])
        XCTAssertEqual(model.warnings.count, 1)
        XCTAssertTrue(model.warnings[0].contains("Model"))
        XCTAssertNil(model.errorMessage)
    }

    func testUnauthorizedAbortsTheSearch() async {
        let (model, _) = await searched(runStates: ["s1": (401, "{}")])
        XCTAssertEqual(model.errorMessage, GraphError.unauthorized.errorDescription)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    func testCancelledSearchReportsIt() async {
        _ = route(runStates: [:])
        let model = DeviceSearchViewModel()
        model.query = "a@x.com"
        let task = Task { await model.search(client: .mocked()) }
        task.cancel()
        await task.value
        XCTAssertEqual(model.infoMessage, "Search cancelled.")
        XCTAssertFalse(model.isSearching)
    }

    func testResetClearsEverything() async {
        let (model, _) = await searched(runStates: ["s1": page(runState("r1", device: "d1", value: "v"))])
        model.reset()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.hasSearched)
    }

    func testDevicesAreListedEvenWithoutResults() async throws {
        let (model, _) = await searched(runStates: ["s1": page(runState("r1", device: "d1", value: "v"))])
        XCTAssertEqual(model.devices.map(\.deviceName), ["Mac1", "Mac2"])
        XCTAssertEqual(model.rows.map(\.deviceName), ["Mac1"])
    }

    func testReadsOnlyTheSourcesOfTheSelectedDevicesOS() async throws {
        let log = RequestLog()
        let devices = """
        {"value":[{"id":"w1","deviceName":"PC1","serialNumber":"W","operatingSystem":"Windows"},
                  {"id":"l1","deviceName":"Box1","serialNumber":"L","operatingSystem":"Linux"}]}
        """
        MockURLProtocol.handler = { request in
            let url = request.url!
            log.add(url)
            let body: String
            if url.path.hasSuffix("/managedDevices") {
                body = devices
            } else if url.path.hasSuffix("/deviceHealthScripts") {
                body = #"{"value":[{"id":"h1","displayName":"BitLocker"}]}"#
            } else if url.path.hasSuffix("/deviceComplianceScripts") {
                body = #"{"value":[{"id":"c1","displayName":"Kernel"}]}"#
            } else if url.path.hasSuffix("/h1/deviceRunStates") {
                body = #"{"value":[{"id":"r1","detectionState":"success","preRemediationDetectionScriptOutput":"enabled","managedDevice":{"id":"w1"}}]}"#
            } else if url.path.hasSuffix("/c1/deviceRunStates") {
                body = #"{"value":[{"id":"r2","detectionState":"compliant","scriptOutput":"6.8","managedDevice":{"id":"l1"}}]}"#
            } else {
                body = #"{"value":[]}"#
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = DeviceSearchViewModel()
        model.query = "a@x.com"
        await model.search(client: .mocked())
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.hasRead)
        await readEverything(model)

        let byOS = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.os, $0) })
        XCTAssertEqual(byOS["Windows"]?.value, "enabled")
        XCTAssertEqual(byOS["Windows"]?.runState, "success")
        XCTAssertEqual(byOS["Linux"]?.value, "6.8")
        XCTAssertEqual(byOS["Linux"]?.runState, "compliant")
        XCTAssertTrue(model.warnings.isEmpty)

        model.osFilter = "linux"
        XCTAssertEqual(model.visibleRows.map(\.deviceName), ["Box1"])
        let paths = log.urls.map(\.path)
        for source in ["deviceHealthScripts", "deviceComplianceScripts"] {
            XCTAssertTrue(paths.contains { $0.hasSuffix("/\(source)") }, source)
        }
        XCTAssertFalse(paths.contains { $0.hasSuffix("/deviceCustomAttributeShellScripts") })
    }

    func testMacSelectionDoesNotReadWindowsOrLinuxSources() async {
        let log = route(runStates: ["s1": page(runState("r1", device: "d1", value: "v"))])
        let model = DeviceSearchViewModel()
        model.query = "a@x.com"
        await model.search(client: .mocked())
        XCTAssertFalse(log.urls.contains { $0.path.hasSuffix("/deviceCustomAttributeShellScripts") })
        model.selection = ["d1"]
        await model.loadAttributes(client: .mocked())
        XCTAssertEqual(Set(model.choices.map(\.config.id)), ["macOS"])
        XCTAssertTrue(model.rows.isEmpty)
        model.selectAllAttributes()
        await model.readAttributes(client: .mocked())
        XCTAssertEqual(model.rows.map(\.deviceName), ["Mac1"])
        let paths = log.urls.map(\.path)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/deviceHealthScripts") || $0.hasSuffix("/deviceComplianceScripts") })
    }

    func testIOSAndAndroidDevicesAreLeftOut() async {
        let mixed = #"{"value":[{"id":"p1","deviceName":"iPhone","operatingSystem":"iOS"},{"id":"a1","deviceName":"Pixel","operatingSystem":"Android"},{"id":"m1","deviceName":"Mac","operatingSystem":"macOS"}]}"#
        _ = route(devices: mixed, runStates: [:])
        let model = DeviceSearchViewModel()
        model.query = "a@x.com"
        await model.search(client: .mocked())
        XCTAssertEqual(model.devices.map(\.deviceName), ["Mac"])

        let phonesOnly = #"{"value":[{"id":"p1","deviceName":"iPhone","operatingSystem":"iOS"}]}"#
        _ = route(devices: phonesOnly, runStates: [:])
        await model.search(client: .mocked())
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(model.infoMessage, "No macOS, Windows or Linux devices found for a@x.com.")
    }

    func testOnlyTickedAttributesAreRead() async {
        let log = route(runStates: ["s1": page(runState("r1", device: "d1", value: "a")), "s2": page(runState("r2", device: "d1", value: "b"))])
        let model = DeviceSearchViewModel()
        model.query = "a@x.com"
        await model.search(client: .mocked())
        model.selection = ["d1"]
        await model.loadAttributes(client: .mocked())
        XCTAssertEqual(model.choices.map(\.script.title), ["Battery", "Model"])
        XCTAssertFalse(log.urls.contains { $0.path.hasSuffix("/deviceRunStates") })
        model.toggleAttribute("macOS/s2")
        await model.readAttributes(client: .mocked())
        XCTAssertEqual(model.rows.map(\.value), ["b"])
        XCTAssertEqual(log.urls.filter { $0.path.hasSuffix("/deviceRunStates") }.map(\.path), ["/beta/deviceManagement/deviceCustomAttributeShellScripts/s2/deviceRunStates"])
    }

    func testChangingDeviceSelectionDropsAttributesAndResults() async {
        let (model, _) = await searched(runStates: ["s1": page(runState("r1", device: "d1", value: "a"))])
        XCTAssertFalse(model.rows.isEmpty)
        model.selection = ["d2"]
        XCTAssertTrue(model.choices.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.hasRead)
    }

    func testOSFilterNarrowsTheDeviceListAndDropsHiddenSelections() async {
        let (model, _) = await searched(runStates: [:], devices: """
        {"value":[{"id":"m","deviceName":"Mac","operatingSystem":"macOS"},{"id":"w","deviceName":"PC","operatingSystem":"Windows"}]}
        """)
        XCTAssertEqual(model.visibleDevices.map(\.deviceName), ["Mac", "PC"])
        model.selection = ["m", "w"]
        model.osFilter = "windows"
        XCTAssertEqual(model.visibleDevices.map(\.deviceName), ["PC"])
        XCTAssertEqual(model.selection, ["w"])
        model.osFilter = nil
        XCTAssertEqual(model.visibleDevices.count, 2)
    }

    func testDeviceSearchMergesNameAndSerialMatchesWithoutDuplicates() async {
        let log = route(runStates: [:])
        let model = DeviceSearchViewModel(mode: .device)
        model.query = "Mac"
        await model.search(client: .mocked())
        XCTAssertEqual(model.devices.map(\.deviceName), ["Mac1", "Mac2"])
        let filters = log.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }?.value }
        XCTAssertEqual(filters, ["contains(deviceName,'Mac')", "contains(serialNumber,'Mac')"])
    }

    func testDeviceSearchRejectsEmptyTermAndKeepsGoingWhenOneQueryFails() async {
        let empty = DeviceSearchViewModel(mode: .device)
        await empty.search(client: .mocked())
        XCTAssertEqual(empty.errorMessage, SearchMode.device.invalidMessage)

        MockURLProtocol.handler = { request in
            let url = request.url!
            let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }?.value ?? ""
            let failing = filter.contains("serialNumber")
            let body = failing ? "{}" : #"{"value":[{"id":"d1","deviceName":"Mac1","operatingSystem":"macOS"}]}"#
            return (HTTPURLResponse(url: url, statusCode: failing ? 400 : 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = DeviceSearchViewModel(mode: .device)
        model.query = "Mac"
        await model.search(client: .mocked())
        XCTAssertEqual(model.devices.map(\.deviceName), ["Mac1"])
        XCTAssertEqual(model.warnings.count, 1)
        XCTAssertNil(model.errorMessage)
    }
}

extension DeviceSearchViewModelTests {
    func testFullReadsAreKeptAndTheNextReadReusesThem() async throws {
        let log = route(runStates: ["s1": page(runState("r1", device: "d1", value: "88%"), runState("r2", device: "someone-else", value: "99%"))])
        let cache = ResultsCache()
        let model = DeviceSearchViewModel(cache: cache)
        model.query = "a@x.com"
        await model.search(client: .mocked())
        await readEverything(model)
        XCTAssertEqual(model.rows.map(\.value), ["88%"])
        let battery = ScriptSummary(id: "s1", displayName: "Battery", customAttributeName: nil, lastModifiedDateTime: nil)
        let stored = try XCTUnwrap(cache.entry(ResultsCache.key(config: .macOS, script: battery)))
        XCTAssertEqual(stored.items.count, 2)
        XCTAssertEqual(stored.rows.count, 2)

        let batteryReads = { log.urls.filter { $0.path.hasSuffix("/s1/deviceRunStates") }.count }
        let before = batteryReads()
        await model.readAttributes(client: .mocked())
        XCTAssertEqual(batteryReads(), before)
        XCTAssertEqual(model.rows.map(\.value), ["88%"])
    }
}
