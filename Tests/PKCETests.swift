import XCTest
@testable import DeviceLookupForIntune

final class PKCETests: XCTestCase {
    func testChallengeMatchesRFC7636Example() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomVerifierIsURLSafeAndLongEnough() {
        let verifier = PKCE().verifier
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(verifier, PKCE().verifier)
    }

    func testBase64URLRoundTrip() {
        let data = Data([0xfb, 0xff, 0xfe, 0x01])
        XCTAssertEqual(Data(base64URLEncoded: data.base64URLEncodedString()), data)
    }
}
