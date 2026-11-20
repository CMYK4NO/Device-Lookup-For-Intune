import AppKit
import Foundation
import os

/// OAuth 2.0 authorization code flow with PKCE through the default browser and a loopback redirect.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var account: Account?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private static let refreshMargin: TimeInterval = 300

    private let store: SessionStore
    private let urlSession: URLSession
    private let openBrowser: (URL) -> Bool
    private let logger = Logger(subsystem: "DeviceLookupForIntune", category: "auth")
    private var cached: [String: (token: String, expiresAt: Date)] = [:]
    private var silentTasks: [String: Task<String?, Error>] = [:]
    /// Browser sign-ins in progress. Graph calls that need one while it runs wait for it, so a burst of requests after the
    /// session expired opens one browser tab, not one per request.
    private var browserTasks: [String: Task<String, Error>] = [:]

    init(
        store: SessionStore = InMemorySessionStore(),
        urlSession: URLSession = GraphClient.defaultSession,
        openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.store = store
        self.urlSession = urlSession
        self.openBrowser = openBrowser
        account = store.load()?.account
    }

    // MARK: UI entry points

    func beginSignIn(_ configuration: AuthConfiguration) {
        guard browserTasks.isEmpty else { return }
        errorMessage = nil
        Task { _ = try? await browserSignIn(configuration) }
    }

    func cancelSignIn() {
        browserTasks.values.forEach { $0.cancel() }
    }

    func signOut() {
        browserTasks.values.forEach { $0.cancel() }
        silentTasks.values.forEach { $0.cancel() }
        store.clear()
        cached = [:]
        account = nil
        errorMessage = nil
        logger.info("Signed out")
    }

    // MARK: Token access for Graph calls

    /// Cached token, then silent refresh, then interactive sign-in.
    func accessToken(_ configuration: AuthConfiguration) async throws -> String {
        if let hit = cached[configuration.tokenKey], hit.expiresAt > Date().addingTimeInterval(Self.refreshMargin) {
            return hit.token
        }
        if let token = try await silentToken(configuration) {
            return token
        }
        return try await browserSignIn(configuration)
    }

    // MARK: Flows

    /// Opens the browser once per configuration at a time; later callers wait for the same sign-in. The sign-in screen
    /// shows it as waiting, with Cancel.
    private func browserSignIn(_ configuration: AuthConfiguration) async throws -> String {
        let key = configuration.tokenKey
        if let running = browserTasks[key] { return try await running.value }
        let task = Task { try await interactiveSignIn(configuration) }
        browserTasks[key] = task
        isBusy = true
        defer {
            if browserTasks[key] == task { browserTasks[key] = nil }
            isBusy = !browserTasks.isEmpty
        }
        do {
            return try await task.value
        } catch {
            report(error)
            throw error
        }
    }

    private func silentToken(_ configuration: AuthConfiguration) async throws -> String? {
        let key = configuration.tokenKey
        if let running = silentTasks[key] { return try await running.value }
        let task = Task { try await refreshSilently(configuration) }
        silentTasks[key] = task
        defer { silentTasks[key] = nil }
        return try await task.value
    }

    private func refreshSilently(_ configuration: AuthConfiguration) async throws -> String? {
        guard let session = store.load() else { return nil }
        do {
            let tokens = try await TokenClient(configuration: configuration, session: urlSession)
                .refresh(refreshToken: session.refreshToken)
            finish(tokens, configuration: configuration, previous: session)
            return tokens.accessToken
        } catch AuthError.signInRequired {
            store.clear()
            cached = [:]
            account = nil
            errorMessage = AuthError.signInRequired.errorDescription
            return nil
        }
    }

    private func interactiveSignIn(_ configuration: AuthConfiguration) async throws -> String {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        let redirectURI = "http://localhost:\(port)"
        let pkce = PKCE()
        let state = PKCE.randomString(byteCount: 16)
        let url = try configuration.authorizeURL(redirectURI: redirectURI, codeChallenge: pkce.challenge, state: state)

        logger.info("Opening browser for sign-in")
        guard openBrowser(url) else { throw AuthError.browserUnavailable }

        let items = try await server.waitForCallback()
        let parameters = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        guard parameters["state"] == state else { throw AuthError.stateMismatch }
        if let error = parameters["error"] {
            throw AuthError.from(oauthError: error, description: parameters["error_description"])
        }
        guard let code = parameters["code"] else { throw AuthError.invalidResponse }

        let tokens = try await TokenClient(configuration: configuration, session: urlSession)
            .exchange(code: code, codeVerifier: pkce.verifier, redirectURI: redirectURI)
        finish(tokens, configuration: configuration, previous: nil)
        logger.info("Sign-in completed")
        return tokens.accessToken
    }

    private func finish(_ tokens: TokenResponse, configuration: AuthConfiguration, previous: StoredSession?) {
        let signedIn = IDToken.account(from: tokens.idToken)
            ?? previous?.account
            ?? Account(name: "Signed-in user", username: "")
        if let refreshToken = tokens.refreshToken ?? previous?.refreshToken {
            store.save(StoredSession(refreshToken: refreshToken, account: signedIn))
        }
        cached[configuration.tokenKey] = (tokens.accessToken, Date().addingTimeInterval(TimeInterval(tokens.expiresIn)))
        account = signedIn
    }

    private func report(_ error: Error) {
        if error is CancellationError {
            errorMessage = AuthError.cancelled.errorDescription
            return
        }
        errorMessage = error.localizedDescription
        logger.error("Authentication failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension AuthService {
    /// A Graph client whose tokens come from this service (silent first, interactive fallback).
    func graphClient(_ configuration: AuthConfiguration) -> GraphClient {
        GraphClient(tokenProvider: { [self] in try await accessToken(configuration) })
    }
}
