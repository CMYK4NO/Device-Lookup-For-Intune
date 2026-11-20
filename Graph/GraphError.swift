import Foundation

enum GraphError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(message: String?)
    case throttled
    case network(String)
    case http(status: Int, message: String?)
    case invalidRequest
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Microsoft Graph rejected the sign-in token (401). Sign out and sign in again."
        case .forbidden(let message):
            return "Access denied (403). Either a Graph permission has no admin consent, or your account lacks the Intune role permission to read device configurations and managed devices." + (message.map { " Graph says: \($0)" } ?? "")
        case .throttled:
            return "Microsoft Graph is throttling requests. Wait a few minutes and try again."
        case .network(let message):
            return "Network error: \(message)"
        case .http(let status, let message):
            return "Microsoft Graph error \(status)" + (message.map { ": \($0)" } ?? "")
        case .invalidRequest:
            return "Could not build the Microsoft Graph request."
        case .invalidResponse:
            return "Unexpected response from Microsoft Graph."
        case .decoding(let detail):
            return "Could not read the Microsoft Graph response: \(detail)"
        }
    }
}
