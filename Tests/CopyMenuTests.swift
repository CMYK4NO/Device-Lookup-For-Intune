import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class CopyMenuTests: XCTestCase {
    func testRowsBecomeTabSeparatedLinesWithTheFullText() {
        let long = String(repeating: "x", count: 300)
        let rows = [
            [CopyField(title: "Device", text: "Mac"), CopyField(title: "Value", text: "line one\r\nline\ttwo \(long)")],
            [CopyField(title: "Device", text: "PC"), CopyField(title: "Value", text: "")],
        ]
        XCTAssertEqual(TableText.lines(of: rows), "Mac\tline one line two \(long)\nPC\t")
        XCTAssertTrue(TableText.items(for: []).isEmpty)
        XCTAssertEqual(TableText.items(for: rows).count, 1)
    }

    func testSearchRowsCopyTheColumnsInTableOrder() {
        let row = SearchResultRow(
            id: "r", deviceID: "d1", deviceName: "Mac", osID: "macOS", os: "macOS", serial: "S1",
            attribute: "Battery", value: "88%", runState: "success", lastUpdated: nil
        )
        XCTAssertEqual(row.copyFields.map(\.title), ["Custom Attribute", "Device", "OS", "Serial", "Value", "Result", "Date"])
        XCTAssertEqual(row.copyFields.map(\.text), ["Battery", "Mac", "macOS", "S1", "88%", "success", ""])
    }

    func testValueColumnGrowsWithTheLongestValueWithinLimits() {
        XCTAssertEqual(ValueCell.idealWidth(for: [String]()), 320)
        XCTAssertEqual(ValueCell.idealWidth(for: ["short"]), 320)
        XCTAssertEqual(ValueCell.idealWidth(for: ["short", String(repeating: "W", count: 500)]), 700)
        let medium = ValueCell.idealWidth(for: ["short", String(repeating: "a", count: 70)])
        XCTAssertGreaterThan(medium, 320)
        XCTAssertLessThan(medium, 700)
    }
}
