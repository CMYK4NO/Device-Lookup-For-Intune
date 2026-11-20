import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class DeviceStatusTests: XCTestCase {
    private let deviceID = "11111111-1111-1111-1111-111111111111"
    private let userID = "44444444-4444-4444-4444-444444444444"

    private func device(userId: String? = "44444444-4444-4444-4444-444444444444") -> ManagedDevice {
        ManagedDevice(id: deviceID, deviceName: "Mac", serialNumber: nil, userPrincipalName: nil,
                      operatingSystem: "macOS", osVersion: nil, azureADDeviceId: nil, userId: userId)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Answers by URL path suffix with (status, body); anything else is 404.
    private func serve(_ routes: [String: (Int, String)]) {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let hit = routes.first { request.url!.path.hasSuffix($0.key) }
            return (HTTPURLResponse(url: request.url!, statusCode: hit?.value.0 ?? 404, httpVersion: nil, headerFields: nil)!,
                    Data((hit?.value.1 ?? "{}").utf8))
        }
    }

    private func report(_ rows: [[String]], columns: [String] = ["PolicyId", "PolicyName", "PolicyStatus"]) -> String {
        let schema = columns.map { #"{"Column":"\#($0)"}"# }.joined(separator: ",")
        let values = rows.map { row in "[" + row.map { "\"\($0)\"" }.joined(separator: ",") + "]" }.joined(separator: ",")
        return #"{"TotalRowCount":\#(rows.count),"Schema":[\#(schema)],"Values":[\#(values)]}"#
    }

    func testCompliancePoliciesComeFromTheDeviceReportPerUserWithTheirCheckDate() async throws {
        serve(["/getDevicePoliciesComplianceReport": (200, report([
            ["p2", "mac baseline", "4", "Not compliant", "a@contoso.com", "2026-11-18T09:00:00"],
            ["p1", "Another policy", "2", "Compliant", "a@contoso.com", "2026-11-18T08:00:00"],
            ["p2", "mac baseline", "2", "Compliant", "", "2026-11-10T08:00:00"],
        ], columns: ["PolicyId", "PolicyName", "PolicyStatus", "PolicyStatus_loc", "UPN", "LastContact"]))])
        let status = try await DeviceStatusLoader.load(.compliance, for: device(), client: .mocked())

        XCTAssertEqual(status.compliancePolicies.map(\.name), ["Another policy", "mac baseline", "mac baseline"])
        let user = try XCTUnwrap(status.compliancePolicies.first { $0.name == "mac baseline" && $0.user == "a@contoso.com" })
        XCTAssertEqual(user.state, "Not compliant")
        XCTAssertEqual(user.lastReported, GraphDate.parse("2026-11-18T09:00:00Z"))
        let noUser = try XCTUnwrap(status.compliancePolicies.first { $0.name == "mac baseline" && $0.user == nil })
        XCTAssertEqual(noUser.state, "Compliant")
        XCTAssertEqual(noUser.lastReported, GraphDate.parse("2026-11-10T08:00:00Z"))
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.bodyString.contains("(DeviceId eq '\(deviceID)')"))
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testConfigurationsAreSorted() async throws {
        serve(["/getConfigurationPoliciesReportForDevice": (200, report([["c2", "b Wifi", "Succeeded"], ["c1", "A Security", "Error"]]))])
        let status = try await DeviceStatusLoader.load(.configuration, for: device(), client: .mocked())
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(status.configurations.map(\.name), ["A Security", "b Wifi"])
        XCTAssertEqual(status.configurations.map(\.state), ["Error", "Succeeded"])
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testConfigurationsKeepTheirLastStatusChangeInUTC() async throws {
        serve(["/getConfigurationPoliciesReportForDevice": (200, #"""
            {"TotalRowCount":1,"Schema":[{"Column":"PolicyId"},{"Column":"PolicyName"},{"Column":"UPN"},{"Column":"PspdpuLastModifiedTimeUtc"}],
             "Values":[["c1","Wi-Fi","a@contoso.com","2026-09-02T13:07:39"]]}
            """#)])
        let status = try await DeviceStatusLoader.load(.configuration, for: device(), client: .mocked())
        XCTAssertEqual(status.configurations.first?.lastUpdated, ISO8601DateFormatter().date(from: "2026-09-02T13:07:39Z"))
        XCTAssertEqual(status.configurations.first?.user, "a@contoso.com")
    }

    func testAppsUseUserAndDevice() async throws {
        serve(["/mobileAppIntentAndStates/\(deviceID)": (200, #"{"mobileAppList":[{"applicationId":"a2","displayName":"Zoom","displayVersion":"6.1","mobileAppIntent":"requiredInstall","installState":"installed"},{"applicationId":"a1","displayName":"Edge","installState":"notInstalled"}]}"#)])
        let status = try await DeviceStatusLoader.load(.apps, for: device(), client: .mocked())

        XCTAssertEqual(status.apps.map(\.name), ["Edge", "Zoom"])
        XCTAssertEqual(status.apps.last?.installState, "installed")
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/beta/users/\(userID)/mobileAppIntentAndStates/\(deviceID)")
    }

    func testAppsCarryWhenTheirInstallStatusLastChangedOnTheDevice() async throws {
        let zoom = "aaaaaaaa-0000-0000-0000-000000000001", teams = "aaaaaaaa-0000-0000-0000-000000000002"
        let list = #"{"mobileAppList":[{"applicationId":"\#(zoom)","displayName":"Zoom","installState":"installed"},{"applicationId":"\#(teams)","displayName":"Teams","installState":"failed"},{"applicationId":"aaaaaaaa-0000-0000-0000-000000000003","displayName":"Other","installState":"notInstalled"}]}"#
        let lock = NSLock(), id = deviceID
        var bodies: [String] = []
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            var body = list
            if request.url!.path.hasSuffix("retrieveDeviceAppInstallationStatusReport") {
                let sent = request.bodyString
                lock.lock()
                bodies.append(sent)
                lock.unlock()
                let date = sent.contains(zoom) ? "2026-03-01T10:00:00" : "2026-04-02T11:00:00"
                body = #"{"TotalRowCount":2,"Schema":[{"Column":"DeviceId"},{"Column":"DeviceName"},{"Column":"LastModifiedDateTime"}],"Values":[["99999999-9999-9999-9999-999999999999","Mac","2026-01-01T00:00:00"],["\#(id)","Mac","\#(date)"]]}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let status = try await DeviceStatusLoader.load(.apps, for: device(), client: .mocked())

        XCTAssertEqual(status.apps.map(\.name), ["Other", "Teams", "Zoom"])
        XCTAssertEqual(status.apps.map(\.lastModified), [nil, GraphDate.parse("2026-04-02T11:00:00Z"), GraphDate.parse("2026-03-01T10:00:00Z")])
        XCTAssertEqual(bodies.count, 2, "only installed or failed apps are looked up")
        XCTAssertTrue(bodies.allSatisfy { $0.contains(#""search":"Mac""#) })
    }

    func testNoPrimaryUserIsANoteForApps() async throws {
        serve([:])
        let status = try await DeviceStatusLoader.load(.apps, for: device(userId: nil), client: .mocked())

        XCTAssertTrue(status.apps.isEmpty)
        XCTAssertTrue(status.notes.contains { $0.hasPrefix(StatusPart.apps.title) })
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testFailingPartBecomesANote() async throws {
        serve(["/getConfigurationPoliciesReportForDevice": (403, #"{"error":{"message":"denied"}}"#)])
        let status = try await DeviceStatusLoader.load(.configuration, for: device(), client: .mocked())

        XCTAssertTrue(status.configurations.isEmpty)
        XCTAssertEqual(status.notes.count, 1)
        XCTAssertTrue(status.notes[0].hasPrefix(StatusPart.configuration.title))
    }

    func testThrottlingBecomesANoteAndOpeningTheTabAgainRetries() async {
        MockURLProtocol.reply(status: 429, json: "{}")
        let model = DeviceStatusViewModel()
        await model.load(.configuration, devices: [device()], client: .mocked())
        XCTAssertEqual(model.statuses[deviceID]?.notes.count, 1)
        XCTAssertFalse(model.statuses[deviceID]?.loaded.contains(.configuration) ?? true)

        serve(["/getConfigurationPoliciesReportForDevice": (200, report([["c1", "Wifi", "Succeeded"]]))])
        await model.load(.configuration, devices: [device()], client: .mocked())
        XCTAssertTrue(model.statuses[deviceID]?.notes.isEmpty ?? false)
        XCTAssertEqual(model.statuses[deviceID]?.configurations.count, 1)
    }

    func testUnauthorizedAbortsTheLoad() async {
        MockURLProtocol.reply(status: 401, json: "{}")
        do {
            _ = try await DeviceStatusLoader.load(.compliance, for: device(), client: .mocked())
            XCTFail("401 must abort")
        } catch {
            XCTAssertEqual(error as? GraphError, .unauthorized)
        }
    }

    func testStateText() {
        XCTAssertEqual(StateText.readable("nonCompliant"), "Not compliant")
        XCTAssertEqual(StateText.readable("notInstalled"), "Not installed")
        XCTAssertEqual(StateText.readable("inGracePeriod"), "In grace period")
        XCTAssertEqual(StateText.readable(nil), "Unknown")
        XCTAssertTrue(StateText.isInstalledOrFailed("installed"))
        XCTAssertTrue(StateText.isInstalledOrFailed("failed"))
        XCTAssertTrue(StateText.isFailedInstall("uninstallFailed"))
        XCTAssertFalse(StateText.isInstalledOrFailed("notInstalled"))
        XCTAssertFalse(StateText.isInstalledOrFailed("unknown"))
        XCTAssertFalse(StateText.isInstalledOrFailed(nil))
    }

    func testPathSegmentsMustBePlainIdentifiers() throws {
        XCTAssertEqual(try DeviceStatusLoader.segment("abc-1_2"), "abc-1_2")
        XCTAssertThrowsError(try DeviceStatusLoader.segment("a/b"))
        XCTAssertThrowsError(try DeviceStatusLoader.segment("a?b"))
        XCTAssertThrowsError(try DeviceStatusLoader.segment(""))
    }

    func testPartsAreLoadedOnceAndKeptSeparately() async {
        serve(["/getDevicePoliciesComplianceReport": (200, report([["p1", "Policy", "Compliant"]], columns: ["PolicyId", "PolicyName", "PolicyStatus_loc"]))])
        let model = DeviceStatusViewModel()
        await model.load(.compliance, devices: [device()], client: .mocked())
        await model.load(.compliance, devices: [device()], client: .mocked())

        XCTAssertEqual(model.statuses[deviceID]?.compliancePolicies.map(\.name), ["Policy"])
        XCTAssertEqual(model.statuses[deviceID]?.loaded, [.compliance])
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertFalse(model.isLoading)

        model.clear()
        XCTAssertTrue(model.statuses.isEmpty)
    }

    func testSelectionChangeClearsTheStatus() async {
        serve(["/getDevicePoliciesComplianceReport": (200, report([["p1", "Policy", "Compliant"]], columns: ["PolicyId", "PolicyName", "PolicyStatus_loc"]))])
        let search = DeviceSearchViewModel()
        await search.status.load(.compliance, devices: [device()], client: .mocked())
        XCTAssertFalse(search.status.statuses.isEmpty)

        search.selection = ["x"]
        XCTAssertTrue(search.status.statuses.isEmpty)
    }
}
