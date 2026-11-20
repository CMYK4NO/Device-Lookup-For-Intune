import XCTest
@testable import DeviceLookupForIntune

final class SearchModeTests: XCTestCase {
    func testDeviceTermIsTrimmedAndRejectsEmptyOrTooLong() {
        XCTAssertEqual(SearchMode.device.validated("  ABC123XYZ789 \n"), "ABC123XYZ789")
        XCTAssertNil(SearchMode.device.validated("   "))
        XCTAssertNil(SearchMode.device.validated(String(repeating: "a", count: 101)))
        XCTAssertNil(SearchMode.device.validated("bad\u{0007}term"))
    }

    func testUPNModeStillValidatesUPNs() {
        XCTAssertEqual(SearchMode.upn.validated(" a@x.com "), "a@x.com")
        XCTAssertNil(SearchMode.upn.validated("not-a-upn"))
    }

    func testDeviceModeMatchesNameAndSerialWithEscaping() {
        let queries = SearchMode.device.devicesQueries(for: "o'x")
        XCTAssertEqual(queries.map { $0.first { $0.name == "$filter" }?.value }, ["contains(deviceName,'o''x')", "contains(serialNumber,'o''x')"])
        XCTAssertTrue(queries.allSatisfy { $0.first { $0.name == "$select" }?.value == UPNQuery.deviceFields })
    }

    func testUPNModeUsesOneQuery() {
        XCTAssertEqual(SearchMode.upn.devicesQueries(for: "a@x.com").count, 1)
    }
}
