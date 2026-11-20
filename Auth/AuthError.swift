import Foundation

enum AuthError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case timedOut
    case browserUnavailable
    case stateMismatch
    case signInRequired
    case missingConsent
    case wrongTenant
    case network(String)
    case server(code: String, description: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Enter the Tenant ID and Client ID in Settings first."
        case .cancelled:
            return "Sign-in was cancelled."
        case .timedOut:
            return "Sign-in timed out. Try again."
        case .browserUnavailable:
            return "Could not open the default browser."
        case .stateMismatch:
            return "The sign-in response did not match the request. Try again."
        case .signInRequired:
            return "Your session has expired. Sign in again."
        case .missingConsent:
            return "Consent is missing for the required Microsoft Graph permissions. Ask a tenant admin to grant admin consent for the app registration."
        case .wrongTenant:
            return "The Tenant ID or Client ID is wrong, or the account does not belong to this tenant. Check Settings."
        case .network(let message):
            return "Network error: \(message)"
        case .server(let code, let description):
            let detail = description?.components(separatedBy: .newlines).first
            return "Sign-in failed (\(code))" + (detail.map { ": \($0)" } ?? "")
        case .invalidResponse:
            return "Unexpected response from Microsoft Entra ID."
        }
    }

    /// Maps an OAuth error response (or redirect error) to a user-facing case.
    static func from(oauthError code: String, description: String?) -> AuthError {
        if let aadsts = description.flatMap(aadstsCode) {
            switch aadsts {
            case "65004": return .cancelled
            case "65001", "90094": return .missingConsent
            case "90002", "700016", "50020": return .wrongTenant
            default: break
            }
        }
        switch code {
        case "consent_required": return .missingConsent
        case "invalid_grant", "interaction_required", "login_required": return .signInRequired
        case "access_denied": return .cancelled
        default: return .server(code: code, description: description)
        }
    }

    private static func aadstsCode(in text: String) -> String? {
        guard let range = text.range(of: #"AADSTS\d+"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("AADSTS".count))
    }
}
