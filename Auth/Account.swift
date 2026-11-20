import Foundation

struct Account: Equatable {
    let name: String
    let username: String
}

/// The refresh token and account kept in memory for the running session.
struct StoredSession: Equatable {
    let refreshToken: String
    let account: Account
}

/// Reads display claims from the id_token returned by the token endpoint (over TLS, not used for authorization).
enum IDToken {
    private struct Claims: Decodable {
        let name: String?
        let preferredUsername: String?
        let upn: String?
        let email: String?

        enum CodingKeys: String, CodingKey {
            case name, upn, email
            case preferredUsername = "preferred_username"
        }
    }

    static func account(from idToken: String?) -> Account? {
        guard let payload = idToken?.split(separator: ".").dropFirst().first,
              let data = Data(base64URLEncoded: String(payload)),
              let claims = try? JSONDecoder().decode(Claims.self, from: data)
        else { return nil }
        let username = claims.preferredUsername ?? claims.upn ?? claims.email ?? ""
        return Account(
            name: claims.name ?? (username.isEmpty ? "Signed-in user" : username),
            username: username
        )
    }
}
