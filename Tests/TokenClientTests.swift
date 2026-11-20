import XCTest
@testable import DeviceLookupForIntune

final class TokenClientTests: XCTestCase {
    private let configuration = AuthConfiguration(tenantID: "t", clientID: "c")
    private var client: TokenClient { TokenClient(configuration: configuration, session: MockURLProtocol.session()) }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testExchangeSendsPKCEAndNoSecret() async throws {
        var body = ""
        MockURLProtocol.handler = { request in
            body = request.bodyString
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"a","refresh_token":"r","id_token":"i","expires_in":"3599"}"#.utf8))
        }
        let tokens = try await client.exchange(code: "code+1", codeVerifier: "ver", redirectURI: "http://localhost:1")
        XCTAssertEqual(tokens.accessToken, "a")
        XCTAssertEqual(tokens.refreshToken, "r")
        XCTAssertEqual(tokens.expiresIn, 3599)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=code%2B1"))
        XCTAssertTrue(body.contains("code_verifier=ver"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2Flocalhost%3A1"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testRefreshRejectedMapsToSignInRequired() async {
        MockURLProtocol.reply(status: 400, json: #"{"error":"invalid_grant","error_description":"AADSTS70008: expired"}"#)
        do {
            _ = try await client.refresh(refreshToken: "r")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .signInRequired)
        }
    }

    func testMissingConsentMapped() async {
        MockURLProtocol.reply(status: 400, json: #"{"error":"invalid_grant","error_description":"AADSTS65001: no consent"}"#)
        do {
            _ = try await client.refresh(refreshToken: "r")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .missingConsent)
        }
    }

    func testNetworkFailureMapped() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await client.refresh(refreshToken: "r")
            XCTFail("expected error")
        } catch {
            guard case .network? = error as? AuthError else { return XCTFail("got \(error)") }
        }
    }

    func testFormEncodeEscapesReservedCharacters() {
        XCTAssertEqual(TokenClient.formEncode(["b": "x y&z", "a": "1+2"]), "a=1%2B2&b=x%20y%26z")
    }
}
