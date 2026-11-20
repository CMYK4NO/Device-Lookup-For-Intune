import XCTest
@testable import DeviceLookupForIntune

final class AuthErrorTests: XCTestCase {
    func testMissingConsent() {
        XCTAssertEqual(AuthError.from(oauthError: "invalid_grant", description: "AADSTS65001: The user has not consented"), .missingConsent)
        XCTAssertEqual(AuthError.from(oauthError: "access_denied", description: "AADSTS90094: admin consent required"), .missingConsent)
        XCTAssertEqual(AuthError.from(oauthError: "consent_required", description: nil), .missingConsent)
    }

    func testWrongTenant() {
        XCTAssertEqual(AuthError.from(oauthError: "invalid_request", description: "AADSTS90002: Tenant not found"), .wrongTenant)
        XCTAssertEqual(AuthError.from(oauthError: "unauthorized_client", description: "AADSTS700016: Application not found"), .wrongTenant)
    }

    func testCancelledAndExpired() {
        XCTAssertEqual(AuthError.from(oauthError: "access_denied", description: "AADSTS65004: user declined"), .cancelled)
        XCTAssertEqual(AuthError.from(oauthError: "access_denied", description: nil), .cancelled)
        XCTAssertEqual(AuthError.from(oauthError: "invalid_grant", description: "AADSTS70008: expired"), .signInRequired)
    }

    func testUnknownKeepsCodeAndFirstLineOfDescription() {
        let error = AuthError.from(oauthError: "weird", description: "first line\r\nTrace ID: 1")
        XCTAssertEqual(error.errorDescription, "Sign-in failed (weird): first line")
    }
}
