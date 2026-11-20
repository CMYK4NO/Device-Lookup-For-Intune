import XCTest
@testable import DeviceLookupForIntune

final class JSONHighlighterTests: XCTestCase {
    private func text(_ json: String) -> String { String(JSONHighlighter.attributed(json).characters) }

    func testEscapedLineBreaksBecomeRealLineBreaks() {
        let json = "{\n  \"resultMessage\" : \"line one\\nline two\",\n  \"runState\" : \"success\"\n}"
        XCTAssertEqual(text(json), "{\n  \"resultMessage\" : \"line one\n    line two\",\n  \"runState\" : \"success\"\n}")
    }

    func testKeepsStructureNullsNumbersAndNestedObjects() {
        let json = "{\n  \"code\" : 0,\n  \"device\" : {\n    \"serial\" : null\n  },\n  \"list\" : [\n    \"a\",\n    \"b\"\n  ]\n}"
        XCTAssertEqual(text(json), json)
    }

    func testQuotesInsideStringsSurvive() {
        let json = "{\n  \"v\" : \"say \\\"hi\\\" : now\"\n}"
        XCTAssertEqual(text(json), "{\n  \"v\" : \"say \"hi\" : now\"\n}")
    }
}
