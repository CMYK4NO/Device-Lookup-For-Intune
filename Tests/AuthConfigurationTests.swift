import XCTest
@testable import DeviceLookupForIntune

final class AuthConfigurationTests: XCTestCase {
    private let configuration = AuthConfiguration(tenantID: "tenant-1", clientID: "client-1")

    func testAuthorizeURL() throws {
        let url = try configuration.authorizeURL(redirectURI: "http://localhost:5000", codeChallenge: "chal", state: "st")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "login.microsoftonline.com")
        XCTAssertEqual(components.path, "/tenant-1/oauth2/v2.0/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client_id"], "client-1")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:5000")
        XCTAssertEqual(query["code_challenge"], "chal")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "st")
        XCTAssertNil(query["client_secret"])
        for scope in ["DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All", "DeviceManagementScripts.Read.All", "offline_access"] {
            XCTAssertTrue(query["scope"]?.contains(scope) == true, scope)
        }
    }

    func testTokenURL() throws {
        XCTAssertEqual(try configuration.tokenURL().absoluteString,
                       "https://login.microsoftonline.com/tenant-1/oauth2/v2.0/token")
    }
}

extension AuthConfigurationTests {
    func testSecretPermissionsAreRequestedOnlyOnDemand() {
        for permission in AuthConfiguration.secretPermissions {
            XCTAssertFalse(configuration.scope.contains(permission), permission)
            XCTAssertTrue(configuration.withSecrets.scope.contains(permission), permission)
        }
    }

    func testUserReadIsNotRequested() {
        XCTAssertFalse(configuration.withSecrets.withApps.scope.contains("User.Read"), "the account name comes from the id token")
    }

    func testAppsPermissionIsRequestedOnlyOnDemand() {
        XCTAssertFalse(configuration.scope.contains("DeviceManagementApps.Read.All"))
        XCTAssertTrue(configuration.withApps.scope.contains("DeviceManagementApps.Read.All"))
        XCTAssertFalse(configuration.withApps.scope.contains("BitlockerKey.Read.All"))
    }
}
