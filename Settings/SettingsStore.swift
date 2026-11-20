import Foundation

/// Tenant configuration persisted in UserDefaults. Holds no secrets.
/// Nothing is built in: an administrator enters the Tenant ID and Client ID of their own app registration in Settings.
final class SettingsStore: ObservableObject {
    enum Key {
        static let tenantID = "tenantID"
        static let clientID = "clientID"
    }

    private let defaults: UserDefaults

    @Published var tenantID: String { didSet { defaults.set(tenantID, forKey: Key.tenantID) } }
    @Published var clientID: String { didSet { defaults.set(clientID, forKey: Key.clientID) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tenantID = defaults.string(forKey: Key.tenantID) ?? ""
        clientID = defaults.string(forKey: Key.clientID) ?? ""
    }

    /// nil until both values are filled in.
    var authConfiguration: AuthConfiguration? {
        let tenant = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenant.isEmpty, !client.isEmpty else { return nil }
        return AuthConfiguration(tenantID: tenant, clientID: client)
    }
}
