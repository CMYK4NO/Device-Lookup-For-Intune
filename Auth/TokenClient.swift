import Foundation

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        if let seconds = try? container.decode(Int.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? container.decode(String.self, forKey: .expiresIn), let seconds = Int(text) {
            expiresIn = seconds
        } else {
            expiresIn = 3600
        }
    }
}

private struct OAuthErrorBody: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Talks to the Entra v2.0 token endpoint. Public client: no client_secret is ever sent.
struct TokenClient {
    let configuration: AuthConfiguration
    let session: URLSession

    func exchange(code: String, codeVerifier: String, redirectURI: String) async throws -> TokenResponse {
        try await post([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "scope": configuration.scope,
        ])
    }

    func refresh(refreshToken: String) async throws -> TokenResponse {
        try await post([
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "scope": configuration.scope,
        ])
    }

    static func formEncode(_ form: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return form.sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    private func post(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: try configuration.tokenURL())
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw AuthError.network(error.localizedDescription)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }

        if http.statusCode == 200 {
            guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                throw AuthError.invalidResponse
            }
            return tokens
        }
        let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
        throw AuthError.from(oauthError: body?.error ?? "http_\(http.statusCode)", description: body?.errorDescription)
    }
}
