import Foundation

/// Tenant/app identity plus the Entra v2.0 endpoints derived from it. No secrets.
struct AuthConfiguration: Equatable {
    static let graphPermissions = [
        "DeviceManagementConfiguration.Read.All",
        "DeviceManagementManagedDevices.Read.All",
        "DeviceManagementScripts.Read.All",
    ]
    private static let baseScopes = ["openid", "profile", "offline_access"]

    /// Read access to passwords and keys. Requested only when one is revealed, so sign-in works without them.
    static let secretPermissions = [
        "DeviceLocalCredential.Read.All",
        "BitlockerKey.Read.All",
        "DeviceManagementManagedDevices.PrivilegedOperations.All",
    ]

    /// Read access to app install status. Requested only when an app is opened, so sign-in works without it.
    static let appPermissions = ["DeviceManagementApps.Read.All"]

    let tenantID: String
    let clientID: String
    var includesSecrets = false
    var includesApps = false

    var scope: String {
        let permissions = Self.graphPermissions
            + (includesSecrets ? Self.secretPermissions : [])
            + (includesApps ? Self.appPermissions : [])
        return (permissions.map { "https://graph.microsoft.com/\($0)" } + Self.baseScopes).joined(separator: " ")
    }

    /// Tokens are kept per tenant, app and scope, so a token of the previous tenant is never reused after Settings change.
    var tokenKey: String {
        "\(tenantID)|\(clientID)|\(scope)"
    }

    var withSecrets: AuthConfiguration {
        var copy = self
        copy.includesSecrets = true
        return copy
    }

    var withApps: AuthConfiguration {
        var copy = self
        copy.includesApps = true
        return copy
    }

    func authorizeURL(redirectURI: String, codeChallenge: String, state: String) throws -> URL {
        var components = endpoint("authorize")
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw AuthError.notConfigured }
        return url
    }

    func tokenURL() throws -> URL {
        guard let url = endpoint("token").url else { throw AuthError.notConfigured }
        return url
    }

    private func endpoint(_ name: String) -> URLComponents {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "login.microsoftonline.com"
        components.path = "/\(tenantID)/oauth2/v2.0/\(name)"
        return components
    }
}
