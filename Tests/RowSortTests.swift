import XCTest
@testable import DeviceLookupForIntune

final class RowSortTests: XCTestCase {
    private func row(_ id: String, device: String, user: String = "", date: String? = nil) throws -> AttributeRow {
        let when = date.map { #","lastStateUpdateDateTime":"\#($0)""# } ?? ""
        let json = #"{"id":"\#(id)","runState":"success","managedDevice":{"id":"d\#(id)","deviceName":"\#(device)","userPrincipalName":"\#(user)"}\#(when)}"#
        let state = try JSONDecoder().decode(RunState.self, from: Data(json.utf8))
        return AttributeRow(item: GraphItem(value: state, raw: json), config: .macOS)
    }

    func testTextColumnsSortIgnoringCaseAndReverse() throws {
        let rows = [try row("1", device: "bravo"), try row("2", device: "Alpha"), try row("3", device: "charlie")]
        XCTAssertEqual(RowSort.sorted(rows, using: [KeyPathComparator(\AttributeRow.device)]).map(\.id), ["2", "1", "3"])
        XCTAssertEqual(RowSort.sorted(rows, using: [KeyPathComparator(\AttributeRow.device, order: .reverse)]).map(\.id), ["3", "1", "2"])
    }

    func testTiesKeepTheirOrder() throws {
        let rows = [try row("1", device: "a", user: "x"), try row("2", device: "b", user: "x"), try row("3", device: "c", user: "a")]
        XCTAssertEqual(RowSort.sorted(rows, using: [KeyPathComparator(\AttributeRow.user)]).map(\.id), ["3", "1", "2"])
    }

    func testDatesSortWithMissingOnesFirst() throws {
        let rows = [try row("1", device: "a", date: "2026-02-01T00:00:00Z"), try row("2", device: "b"), try row("3", device: "c", date: "2026-01-01T00:00:00Z")]
        XCTAssertEqual(RowSort.sorted(rows, using: [KeyPathComparator(\AttributeRow.lastUpdatedSort)]).map(\.id), ["2", "3", "1"])
        XCTAssertEqual(RowSort.sorted(rows, using: [KeyPathComparator(\AttributeRow.lastUpdatedSort, order: .reverse)]).map(\.id), ["1", "3", "2"])
    }

    func testNoComparatorKeepsTheOrder() throws {
        let rows = [try row("2", device: "b"), try row("1", device: "a")]
        XCTAssertEqual(RowSort.sorted(rows, using: []).map(\.id), ["2", "1"])
    }
}
