import XCTest
@testable import DeviceLookupForIntune

final class CSVExporterTests: XCTestCase {
    private func text(_ table: CSVExporter.Table) -> String {
        String(decoding: CSVExporter.data(for: table).dropFirst(3), as: UTF8.self)
    }

    func testEscapeLeavesPlainFieldsAlone() {
        XCTAssertEqual(CSVExporter.escape("plain value"), "plain value")
        XCTAssertEqual(CSVExporter.escape(""), "")
    }

    func testEscapeQuotesCommasQuotesAndLineBreaks() {
        XCTAssertEqual(CSVExporter.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVExporter.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExporter.escape("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(CSVExporter.escape("line1\r\nline2"), "\"line1\r\nline2\"")
    }

    func testEscapeKeepsUnicodeAsIs() {
        XCTAssertEqual(CSVExporter.escape("Zürich ✓ 東京"), "Zürich ✓ 東京")
        XCTAssertEqual(CSVExporter.escape("Zürich, ✓"), "\"Zürich, ✓\"")
    }

    func testDataStartsWithBOMAndUsesCRLFLineEnds() {
        let table = CSVExporter.Table(header: ["A", "B"], rows: [["1", ""], ["x,y", "z"]])
        let data = CSVExporter.data(for: table)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(text(table), "A,B\r\n1,\r\n\"x,y\",z\r\n")
    }

    func testHeaderOnlyWhenThereAreNoRows() {
        XCTAssertEqual(text(CSVExporter.Table(header: ["A"], rows: [])), "A\r\n")
    }

    func testISODate() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-17T06:52:54Z"))
        XCTAssertEqual(CSVExporter.isoDate(date), "2026-11-17T06:52:54Z")
        XCTAssertEqual(CSVExporter.isoDate(nil), "")
    }

    func testFileNamePattern() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-17T12:05:00Z"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(CSVExporter.fileName(os: "macOS", name: "Battery Condition", date: date, timeZone: utc), "macOS-Battery-Condition-20261117-1205.csv")
        XCTAssertEqual(CSVExporter.fileName(os: "all", name: "a/b:c@x.com", date: date, timeZone: utc), "all-a-b-c@x.com-20261117-1205.csv")
        XCTAssertEqual(CSVExporter.fileName(os: "", name: "", date: date, timeZone: utc), "export-export-20261117-1205.csv")
    }

    func testAttributeTableHasOneLinePerRowAndMultilineValuesStayInOneRecord() throws {
        let json = #"{"id":"1","runState":"success","resultMessage":"line one\nline, two","lastStateUpdateDateTime":"2026-11-17T06:52:54Z","managedDevice":{"id":"d1","deviceName":"Mac","userPrincipalName":"a@x.com","serialNumber":"S1","osVersion":"14"}}"#
        let item = GraphItem(value: try JSONDecoder().decode(RunState.self, from: Data(json.utf8)), raw: json)
        let rows = [AttributeRow(item: item, config: .macOS), AttributeRow(item: item, config: .macOS)]
        let table = CSVExporter.table(for: rows)
        XCTAssertEqual(table.header, ["Device", "User (UPN)", "Serial", "OS version", "Value", "Run state", "Last updated"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0], ["Mac", "a@x.com", "S1", "14", "line one\nline, two", "success", "2026-11-17T06:52:54Z"])
        XCTAssertEqual(text(table), "Device,User (UPN),Serial,OS version,Value,Run state,Last updated\r\n"
            + "Mac,a@x.com,S1,14,\"line one\nline, two\",success,2026-11-17T06:52:54Z\r\n"
            + "Mac,a@x.com,S1,14,\"line one\nline, two\",success,2026-11-17T06:52:54Z\r\n")
    }

    func testSearchTable() {
        let row = SearchResultRow(
            id: "r", deviceID: "d1", deviceName: "Mac", osID: "macOS", os: "macOS", serial: "S1",
            attribute: "Battery", value: "88%", runState: "success", lastUpdated: nil
        )
        let table = CSVExporter.table(for: [row])
        XCTAssertEqual(table.header, ["Custom Attribute", "Device", "OS", "Serial", "Value", "Result", "Date"])
        XCTAssertEqual(table.rows, [["Battery", "Mac", "macOS", "S1", "88%", "success", ""]])
    }

    func testFieldsThatSpreadsheetsWouldRunAsFormulasStayText() {
        XCTAssertEqual(CSVExporter.escape("=HYPERLINK(\"http://x\")"), "\"'=HYPERLINK(\"\"http://x\"\")\"")
        XCTAssertEqual(CSVExporter.escape("+1"), "'+1")
        XCTAssertEqual(CSVExporter.escape("-2,5"), "\"'-2,5\"")
        XCTAssertEqual(CSVExporter.escape("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(CSVExporter.escape("\tcmd"), "'\tcmd")
        XCTAssertEqual(CSVExporter.escape("a=b"), "a=b")
    }

    func testStatusTablesUseTheColumnsOnScreen() {
        let row = StatusRow(id: "r", device: "Mac", os: "macOS", serial: "S1", name: "Office", version: "16.9", state: "Installed",
                            user: "a@x.com", osVersion: "26.1")
        let apps = CSVExporter.table(for: [row], part: .apps)
        XCTAssertEqual(apps.header, ["Device", "OS", "Serial", "App", "Version", "Status", "Date"])
        XCTAssertEqual(apps.rows, [["Mac", "macOS", "S1", "Office", "16.9", "Installed", ""]])
        XCTAssertEqual(CSVExporter.table(for: [row], part: .compliance).header,
                       ["Policy", "Device", "User (UPN)", "Serial", "OS version", "Run state", "Last updated"])
        XCTAssertEqual(CSVExporter.table(for: [row], part: .configuration).header.first, "Profile")
        XCTAssertEqual(CSVExporter.table(for: [row], part: .configuration).rows, [["Office", "Mac", "a@x.com", "S1", "26.1", "Installed", ""]])
    }

    func testStatusDatesAreISO8601() {
        var row = StatusRow(id: "r", device: "Mac", os: "macOS", serial: "S1", name: "Wi-Fi", version: "", state: "Succeeded")
        row.date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(CSVExporter.table(for: [row], part: .configuration).rows.first?.last, "1970-01-01T00:00:00Z")
    }
}

extension CSVExporterTests {
    func testValueColumnCanBeLeftOut() throws {
        let json = #"{"id":"1","deviceDisplayName":"Mac","status":"compliant"}"#
        let state = try JSONDecoder().decode(RunState.self, from: Data(json.utf8))
        let row = AttributeRow(item: GraphItem(value: state, raw: json), config: OSSourceConfig.complianceSources[0])
        XCTAssertFalse(OSSourceConfig.complianceSources[0].showsValue)
        XCTAssertFalse(OSSourceConfig.configurationSources[0].showsValue)
        XCTAssertTrue(OSSourceConfig.appSources[0].showsValue)
        XCTAssertEqual(CSVExporter.table(for: [row], includesValue: false).header, ["Device", "User (UPN)", "Serial", "OS version", "Run state", "Last updated"])
        XCTAssertEqual(CSVExporter.table(for: [row], includesValue: false).rows[0].count, 6)
        XCTAssertEqual(CSVExporter.table(for: [row]).header.count, 7)
    }
}
