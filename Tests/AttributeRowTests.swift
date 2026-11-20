import XCTest
@testable import DeviceLookupForIntune

final class AttributeRowTests: XCTestCase {
    private func row(_ json: String, config: OSSourceConfig = .macOS) throws -> AttributeRow {
        let state = try JSONDecoder().decode(RunState.self, from: Data(json.utf8))
        return AttributeRow(item: GraphItem(value: state, raw: json), config: config)
    }

    func testMapsDeviceAndValue() throws {
        let row = try row("""
        {"id":"1","runState":"success","resultMessage":"v1","lastStateUpdateDateTime":"2026-01-01T10:00:00.1234567Z",
         "managedDevice":{"id":"d","deviceName":"Mac","serialNumber":"S1","userPrincipalName":"a@x.com","osVersion":"14.5"}}
        """)
        XCTAssertEqual(row.device, "Mac")
        XCTAssertEqual(row.user, "a@x.com")
        XCTAssertEqual(row.serial, "S1")
        XCTAssertEqual(row.osVersion, "14.5")
        XCTAssertEqual(row.value, "v1")
        XCTAssertFalse(row.valueIsFallback)
        XCTAssertEqual(row.runState, "success")
        XCTAssertNotNil(row.lastUpdated)
        XCTAssertTrue(row.searchText.contains("a@x.com"))
    }

    func testEmptyValueFallsBackToPopulatedFields() throws {
        let row = try row(#"{"id":"1","resultMessage":"","runState":"error","errorCode":5,"errorDescription":"boom","note":null,"managedDevice":{"id":"d"}}"#)
        XCTAssertTrue(row.valueIsFallback)
        XCTAssertEqual(row.value, "errorCode: 5; errorDescription: boom; runState: error")
    }

    func testWindowsUsesDetectionOutputAndDetectionState() throws {
        let row = try row(#"{"id":"1","detectionState":"success","preRemediationDetectionScriptOutput":"win-value","resultMessage":"ignored"}"#, config: .windows)
        XCTAssertEqual(row.value, "win-value")
        XCTAssertEqual(row.runState, "success")
        XCTAssertFalse(row.valueIsFallback)
    }

    func testLinuxUsesScriptOutputAndFallsBackWhenEmpty() throws {
        let filled = try row(#"{"id":"1","detectionState":"compliant","scriptOutput":"{\"a\":1}"}"#, config: .linux)
        XCTAssertEqual(filled.value, #"{"a":1}"#)
        XCTAssertEqual(filled.runState, "compliant")

        let empty = try row(#"{"id":"2","detectionState":"unknown","scriptOutput":"","scriptError":"oops"}"#, config: .linux)
        XCTAssertTrue(empty.valueIsFallback)
        XCTAssertEqual(empty.value, "detectionState: unknown; scriptError: oops")
    }

    func testMissingRunStateFieldGivesEmptyString() throws {
        let row = try row(#"{"id":"1","resultMessage":"x"}"#, config: .windows)
        XCTAssertEqual(row.runState, "")
    }

    func testMissingDeviceGivesEmptyStrings() throws {
        let row = try row(#"{"id":"1","resultMessage":"x","managedDevice":null}"#)
        XCTAssertEqual(row.device, "")
        XCTAssertNil(row.lastUpdated)
        XCTAssertEqual(row.lastUpdatedSort, .distantPast)
    }

    func testGraphDateFormats() {
        XCTAssertNotNil(GraphDate.parse("2026-01-01T10:00:00Z"))
        XCTAssertNotNil(GraphDate.parse("2026-01-01T10:00:00.123Z"))
        XCTAssertNotNil(GraphDate.parse("2026-01-01T10:00:00.1234567Z"))
        XCTAssertEqual(GraphDate.parse("2026-09-02T13:07:39"), GraphDate.parse("2026-09-02T13:07:39Z"))
        XCTAssertEqual(GraphDate.parse("2026-09-02T15:07:39+02:00"), GraphDate.parse("2026-09-02T13:07:39Z"))
        XCTAssertNil(GraphDate.parse("nope"))
        XCTAssertNil(GraphDate.parse(nil))
    }
}

extension AttributeRowTests {
    func testComplianceStatusMapsTopLevelDeviceFields() throws {
        let json = #"{"id":"1","deviceDisplayName":"Mac","userPrincipalName":"a@x.com","deviceModel":"MacBook","status":"nonCompliant","lastReportedDateTime":"2026-01-01T10:00:00Z"}"#
        let state = try JSONDecoder().decode(RunState.self, from: Data(json.utf8))
        let row = AttributeRow(item: GraphItem(value: state, raw: json), config: .compliance)
        XCTAssertEqual(row.device, "Mac")
        XCTAssertEqual(row.user, "a@x.com")
        XCTAssertEqual(row.runState, "nonCompliant")
        XCTAssertEqual(row.value, "MacBook")
        XCTAssertNotNil(row.lastUpdated)
        XCTAssertFalse(row.valueIsFallback)
    }

    func testEmptyStatusValueDoesNotFallBack() throws {
        let json = #"{"id":"1","deviceName":"Mac","deviceId":"d1","installState":"failed","installStateDetail":"","errorCode":9,"lastSyncDateTime":"2026-01-01T10:00:00Z"}"#
        let state = try JSONDecoder().decode(RunState.self, from: Data(json.utf8))
        let row = AttributeRow(item: GraphItem(value: state, raw: json), config: .apps)
        XCTAssertEqual(row.deviceID, "d1")
        XCTAssertEqual(row.runState, "failed")
        XCTAssertEqual(row.value, "")
        XCTAssertFalse(row.valueIsFallback)
    }
}

extension AttributeRowTests {
    func testMacOSConfigurationsShowCompliantAndRemediatedAsSucceeded() throws {
        func state(_ status: String, _ config: OSSourceConfig) throws -> String {
            let json = #"{"id":"1","deviceDisplayName":"Mac","status":"\#(status)"}"#
            let value = try JSONDecoder().decode(RunState.self, from: Data(json.utf8))
            return AttributeRow(item: GraphItem(value: value, raw: json), config: config).runState
        }
        let mac = OSSourceConfig.configurationSources[0]
        XCTAssertEqual(try state("compliant", mac), "Succeeded")
        XCTAssertEqual(try state("remediated", mac), "Succeeded")
        XCTAssertEqual(try state("error", mac), "error")
        XCTAssertEqual(try state("compliant", OSSourceConfig.configurationSources[1]), "compliant")
        XCTAssertEqual(try state("compliant", OSSourceConfig.complianceSources[0]), "compliant")
    }
}
