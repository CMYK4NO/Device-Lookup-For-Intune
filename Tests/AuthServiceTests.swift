import XCTest
@testable import DeviceLookupForIntune

@MainActor
final class AuthServiceTests: XCTestCase {
    private let configuration = AuthConfiguration(tenantID: "t", clientID: "c")
    private let oldSession = StoredSession(
        refreshToken: "old",
        account: Account(name: "Old Name", username: "old@x.com")
    )
    private var requestCount = 0

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeService(store: InMemorySessionStore, openBrowser: @escaping (URL) -> Bool = { _ in true }) -> AuthService {
        AuthService(store: store, urlSession: MockURLProtocol.session(), openBrowser: openBrowser)
    }

    private func idToken(name: String, upn: String) -> String {
        let payload = #"{"name":"\#(name)","preferred_username":"\#(upn)"}"#
        return "h.\(Data(payload.utf8).base64URLEncodedString()).s"
    }

    func testRefreshRotatesTokenAndCaches() async throws {
        let store = InMemorySessionStore()
        store.session = oldSession
        let token = idToken(name: "New Name", upn: "new@x.com")
        MockURLProtocol.handler = { [self] request in
            requestCount += 1
            XCTAssertTrue(request.bodyString.contains("refresh_token=old"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"access-1","refresh_token":"new","id_token":"\#(token)","expires_in":3600}"#.utf8))
        }
        let auth = makeService(store: store)
        XCTAssertEqual(auth.account?.name, "Old Name")

        let token1 = try await auth.accessToken(configuration)
        XCTAssertEqual(token1, "access-1")
        XCTAssertEqual(store.session?.refreshToken, "new")
        XCTAssertEqual(auth.account?.name, "New Name")
        XCTAssertNil(auth.errorMessage)

        let cached = try await auth.accessToken(configuration)
        XCTAssertEqual(cached, "access-1")
        XCTAssertEqual(requestCount, 1)
    }

    func testTokensAreNotSharedBetweenTenants() async throws {
        let store = InMemorySessionStore()
        store.session = oldSession
        MockURLProtocol.handler = { [self] request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"access-\#(requestCount)","refresh_token":"new","expires_in":3600}"#.utf8))
        }
        let auth = makeService(store: store)
        let first = try await auth.accessToken(configuration)
        let other = try await auth.accessToken(AuthConfiguration(tenantID: "other", clientID: "c"))
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(requestCount, 2)
    }

    func testRevokedRefreshTokenClearsSessionThenFallsBackToBrowser() async {
        let store = InMemorySessionStore()
        store.session = oldSession
        MockURLProtocol.reply(status: 400, json: #"{"error":"invalid_grant","error_description":"AADSTS70008: expired"}"#)
        let auth = makeService(store: store, openBrowser: { _ in false })

        do {
            _ = try await auth.accessToken(configuration)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .browserUnavailable)
        }
        XCTAssertNil(auth.account)
        XCTAssertNil(store.session)
        XCTAssertFalse(auth.isBusy)
    }

    func testSignOutClearsEverything() {
        let store = InMemorySessionStore()
        store.session = oldSession
        let auth = makeService(store: store)
        auth.signOut()
        XCTAssertNil(auth.account)
        XCTAssertNil(store.session)
    }

    func testInteractiveFallbackFailsCleanlyWhenBrowserCannotOpen() async {
        let auth = makeService(store: InMemorySessionStore(), openBrowser: { _ in false })
        do {
            _ = try await auth.accessToken(configuration)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .browserUnavailable)
        }
    }
}
