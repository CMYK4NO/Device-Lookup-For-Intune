import Foundation

/// The finished result of one attribute or policy, kept so opening it again is instant.
struct CachedResults {
    let items: [GraphItem<RunState>]
    let rows: [AttributeRow]
    let inventory: [String: ManagedDevice]
    let loadedAt: Date
}

/// Results already read this session, in memory only: nothing about devices is written to disk. The oldest are
/// dropped beyond `capacity`, because every row keeps its raw JSON. Cleared on sign-out.
@MainActor
final class ResultsCache {
    static let shared = ResultsCache()
    static let capacity = 12

    private var entries: [String: CachedResults] = [:]
    /// Keys, least recently stored first.
    private var order: [String] = []

    func entry(_ key: String) -> CachedResults? {
        entries[key]
    }

    func store(_ key: String, _ results: CachedResults) {
        entries[key] = results
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    func clear() {
        entries = [:]
        order = []
    }

    nonisolated static func key(config: OSSourceConfig, script: ScriptSummary) -> String {
        "\(config.id)|\(script.id)"
    }
}
