import XCTest
@testable import DeviceLookupForIntune

final class ModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testRunStateToleratesNullsAndMissingFields() throws {
        let state: RunState = try decode(#"{"id":"1","resultMessage":null,"managedDevice":null}"#)
        XCTAssertEqual(state.id, "1")
        XCTAssertNil(state.managedDevice)
    }

    func testRunStateWithExpandedDevice() throws {
        let state: RunState = try decode("""
        {"id":"1","runState":"success","resultMessage":"v1","lastStateUpdateDateTime":"2026-01-01T10:00:00Z",
         "managedDevice":{"id":"d1","deviceName":"Mac","serialNumber":"S1","userPrincipalName":"a@x.com","operatingSystem":"macOS","osVersion":"14.5"}}
        """)
        XCTAssertEqual(state.managedDevice?.id, "d1")
        XCTAssertEqual(state.managedDevice?.userPrincipalName, "a@x.com")
        XCTAssertEqual(state.lastStateUpdateDateTime, "2026-01-01T10:00:00Z")
    }

    func testScriptSummaryNeedsOnlyID() throws {
        let script: ScriptSummary = try decode(#"{"id":"s1"}"#)
        XCTAssertEqual(script.id, "s1")
        XCTAssertNil(script.displayName)
    }
}
