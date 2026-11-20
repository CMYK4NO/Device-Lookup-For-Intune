import Foundation

protocol SessionStore {
    func load() -> StoredSession?
    func save(_ session: StoredSession)
    func clear()
}

/// Keeps the refresh token and account in memory only. Nothing is written to disk or the Keychain,
/// so the user signs in again after each launch.
final class InMemorySessionStore: SessionStore {
    var session: StoredSession?

    func load() -> StoredSession? { session }
    func save(_ session: StoredSession) { self.session = session }
    func clear() { session = nil }
}
