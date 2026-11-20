import XCTest
@testable import DeviceLookupForIntune

final class UPNQueryTests: XCTestCase {
    func testValidatedAcceptsNormalAndApostropheUPNs() {
        XCTAssertEqual(UPNQuery.validated("  jane.doe@contoso.com \n"), "jane.doe@contoso.com")
        XCTAssertEqual(UPNQuery.validated("o'brien@contoso.com"), "o'brien@contoso.com")
    }

    func testValidatedRejectsMalformedInput() {
        for bad in ["", "plain", "@contoso.com", "a@", "a@@contoso.com", "a@b", "a@.com", "a@com.", "a b@contoso.com", "a@con toso.com"] {
            XCTAssertNil(UPNQuery.validated(bad), bad)
        }
    }

    func testEscapeDoublesSingleQuotes() {
        XCTAssertEqual(UPNQuery.escape("o'brien@x.com"), "o''brien@x.com")
        XCTAssertEqual(UPNQuery.escape("''"), "''''")
        XCTAssertEqual(UPNQuery.escape("plain@x.com"), "plain@x.com")
    }

    func testDevicesQueryAndURL() throws {
        let query = UPNQuery.devicesQuery(upn: "o'brien@x.com")
        XCTAssertEqual(query.first { $0.name == "$filter" }?.value, "userPrincipalName eq 'o''brien@x.com'")
        XCTAssertEqual(query.first { $0.name == "$select" }?.value, "id,deviceName,serialNumber,operatingSystem,osVersion,azureADDeviceId,userId,lastSyncDateTime,enrolledDateTime")

        let url = try GraphClient.mocked().url(path: UPNQuery.devicesPath, query: query)
        XCTAssertEqual(url.path, "/beta/deviceManagement/managedDevices")
        let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }
        XCTAssertEqual(filter?.value, "userPrincipalName eq 'o''brien@x.com'")
    }
}
