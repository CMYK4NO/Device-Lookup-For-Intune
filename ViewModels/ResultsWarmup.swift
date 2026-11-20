import Foundation

/// The few attributes and policies opened most recently, remembered between launches by id only (no device data),
/// so they can be read in the background after sign-in.
struct RecentItems {
    static let limit = 4
    private let defaults: UserDefaults
    private let key = "recentResultItems"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `(source id, item id)` pairs, most recent first.
    var items: [(sourceID: String, itemID: String)] {
        (defaults.stringArray(forKey: key) ?? []).compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    func record(sourceID: String, itemID: String) {
        let entry = "\(sourceID)|\(itemID)"
        var stored = defaults.stringArray(forKey: key) ?? []
        stored.removeAll { $0 == entry }
        stored.insert(entry, at: 0)
        defaults.set(Array(stored.prefix(Self.limit)), forKey: key)
    }
}

/// Reads the recent items in the background after sign-in, two at a time. Opening any table cancels it, so the
/// table you asked for gets the whole connection.
@MainActor
final class ResultsWarmup {
    static let shared = ResultsWarmup()
    static let concurrency = 2

    private var task: Task<Void, Never>?

    func start(items: [(config: OSSourceConfig, script: ScriptSummary)], client: @escaping @MainActor (OSSourceConfig) -> GraphClient, cache: ResultsCache? = nil) {
        cancel()
        let cache = cache ?? .shared
        // Apps need an extra permission that would prompt for sign-in, so they are never read unasked.
        let pending = items.filter { !$0.config.requiresApps && cache.entry(ResultsCache.key(config: $0.config, script: $0.script)) == nil }
        guard !pending.isEmpty else { return }
        task = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(Self.concurrency, pending.count) {
                    let item = pending[next]
                    next += 1
                    group.addTask { @MainActor in await Self.read(item.config, item.script, client: client, cache: cache) }
                }
                while await group.next() != nil, next < pending.count {
                    let item = pending[next]
                    next += 1
                    group.addTask { @MainActor in await Self.read(item.config, item.script, client: client, cache: cache) }
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func read(_ config: OSSourceConfig, _ script: ScriptSummary, client: @MainActor (OSSourceConfig) -> GraphClient, cache: ResultsCache) async {
        let model = AttributeResultsViewModel(config: config, script: script, inventorySource: .shared, cache: cache)
        await model.load(client: client(config))
    }
}
