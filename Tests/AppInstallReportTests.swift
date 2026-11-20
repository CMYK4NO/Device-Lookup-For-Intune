import XCTest
@testable import DeviceLookupForIntune

final class AppInstallReportTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private let appID = "bbbbbbbb-0000-0000-0000-000000000001"
    private let schema = #""Schema":[{"Column":"DeviceName"},{"Column":"UserPrincipalName"},{"Column":"DeviceId"},{"Column":"AppInstallState"},{"Column":"AppInstallStateDetails"},{"Column":"LastModifiedDateTime"}]"#

    func testReportRowsBecomeRunStates() async throws {
        MockURLProtocol.script([(200, [:], #"{"TotalRowCount":1,\#(schema),"Values":[["Mac1","a@x.com","d1","Failed","Missing dependency","2026-01-01T10:00:00Z"]]}"#)])
        let items = try await AppInstallReport.items(appID: appID, client: .mocked())
        XCTAssertEqual(items.count, 1)
        let row = AttributeRow(item: items[0], config: OSSourceConfig.appSources[0])
        XCTAssertEqual(row.device, "Mac1")
        XCTAssertEqual(row.user, "a@x.com")
        XCTAssertEqual(row.deviceID, "d1")
        XCTAssertEqual(row.runState, "Failed")
        XCTAssertEqual(row.value, "Missing dependency")
        XCTAssertNotNil(row.lastUpdated)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix(".retrieveDeviceAppInstallationStatusReport") == true)
    }

    func testRejectsAppIDsThatAreNotIdentifiers() async {
        MockURLProtocol.requests = []
        do {
            _ = try await AppInstallReport.items(appID: "x') or ('1'='1", client: .mocked())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        }
    }
}

extension AppInstallReportTests {
    func testPagingFollowsTheTotalWhenIntuneReturnsShortPages() async throws {
        let schema = #""Schema":[{"Column":"DeviceName"},{"Column":"DeviceId"},{"Column":"AppInstallState"}]"#
        MockURLProtocol.script([
            (200, [:], #"{"TotalRowCount":3,\#(schema),"Values":[["A","d1","Installed"],["B","d2","Installed"]]}"#),
            (200, [:], #"{"TotalRowCount":3,\#(schema),"Values":[["C","d3","Failed"]]}"#),
        ])
        let items = try await AppInstallReport.items(appID: "bbbbbbbb-0000-0000-0000-000000000001", client: .mocked())
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testReadingStopsAtTheLimitAndSendsTheSearch() async throws {
        let schema = #""Schema":[{"Column":"DeviceId"}]"#
        MockURLProtocol.script([
            (200, [:], #"{"TotalRowCount":5,\#(schema),"Values":[["d1"],["d2"]]}"#),
            (200, [:], #"{"TotalRowCount":5,\#(schema),"Values":[["d3"],["d4"]]}"#),
        ])
        let rows = try await ReportReader.rows(path: AppInstallReport.path, filter: "(ApplicationId eq 'a')", search: "Mac", pageSize: 2, limit: 2, client: .mocked())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(MockURLProtocol.requests.first).bodyString.contains(#""search":"Mac""#))
    }
}
