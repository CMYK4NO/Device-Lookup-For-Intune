import XCTest
@testable import DeviceLookupForIntune

final class CompliancePolicyReportTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private let policyID = "bbbbbbbb-0000-0000-0000-000000000001"

    func testReportRowsBecomeRunStatesAndKeepEveryColumn() async throws {
        let body = #"{"TotalRowCount":1,"Schema":[{"Column":"DeviceName"},{"Column":"UPN"},{"Column":"IntuneDeviceId"},{"Column":"PolicyStatus"},{"Column":"LastContact"},{"Column":"Extra"}],"Values":[["ubuntu1","a@x.com","d1","NonCompliant","2026-01-01T10:00:00Z","kept"]]}"#
        MockURLProtocol.script([(200, [:], body)])
        let items = try await CompliancePolicyReport.items(policyID: policyID, client: .mocked())
        XCTAssertEqual(items.count, 1)
        let row = AttributeRow(item: items[0], config: OSSourceConfig.complianceSources[2])
        XCTAssertEqual(row.device, "ubuntu1")
        XCTAssertEqual(row.user, "a@x.com")
        XCTAssertEqual(row.deviceID, "d1")
        XCTAssertEqual(row.runState, "NonCompliant")
        XCTAssertNotNil(row.lastUpdated)
        XCTAssertTrue(items[0].raw.contains("\"Extra\""))
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/getDeviceStatusByCompliacePolicyReport") == true)
        let sent = request.bodyString
        XCTAssertTrue(sent.contains("PolicyId eq '\(policyID)'"))
        XCTAssertTrue(sent.contains("\"select\":[]"))
    }

    func testLinuxReportShowsOSReadableStatusAndLastContact() async throws {
        let body = #"{"TotalRowCount":1,"Schema":[{"Column":"DeviceName"},{"Column":"UPN"},{"Column":"DeviceId"},{"Column":"OS"},{"Column":"PolicyStatus"},{"Column":"PolicyStatus_loc"},{"Column":"LastContact"}],"Values":[["TEST-LINUX","a@x.com","d1","Linux","2","Compliant","2026-09-02T13:07:39"]]}"#
        MockURLProtocol.script([(200, [:], body)])
        let items = try await CompliancePolicyReport.items(policyID: policyID, client: .mocked())
        let row = AttributeRow(item: items[0], config: OSSourceConfig.complianceSources[2])
        XCTAssertEqual(row.osVersion, "Linux")
        XCTAssertEqual(row.runState, "Compliant")
        XCTAssertEqual(row.lastUpdated, GraphDate.parse("2026-09-02T13:07:39Z"))
    }

    func testRejectsPolicyIDsThatAreNotIdentifiers() async {
        MockURLProtocol.requests = []
        do {
            _ = try await CompliancePolicyReport.items(policyID: "x') or ('1'='1", client: .mocked())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        }
    }

    func testLinuxComplianceListsOnlyLinuxSettingsCatalogPolicies() throws {
        let linux = OSSourceConfig.complianceSources[2]
        XCTAssertEqual(linux.listPath, "/deviceManagement/compliancePolicies")
        XCTAssertEqual(linux.report, .compliancePolicy)
        func policy(_ platforms: String?) throws -> ScriptSummary {
            let platform = platforms.map { #","platforms":"\#($0)""# } ?? ""
            return try JSONDecoder().decode(ScriptSummary.self, from: Data(#"{"id":"1","name":"Ubuntu baseline","isAssigned":true\#(platform)}"#.utf8))
        }
        XCTAssertEqual(try policy("linux").title, "Ubuntu baseline")
        XCTAssertTrue(linux.accepts(try policy("linux")))
        XCTAssertFalse(linux.accepts(try policy("windows10")))
        XCTAssertTrue(linux.accepts(try policy(nil)))
    }
}
