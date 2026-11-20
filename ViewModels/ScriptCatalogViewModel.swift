import Foundation

/// Lists of scripts, policies and apps for the sidebar, loaded on demand. Sources that share an endpoint
/// (compliance, configurations and apps are listed once for all OSes) share one request and one list.
@MainActor
final class ScriptCatalogViewModel: ObservableObject {
    struct Listing: Equatable {
        var scripts: [ScriptSummary] = []
        var isLoading = false
        var hasLoaded = false
        var errorMessage: String?
    }

    @Published private(set) var listings: [String: Listing] = [:]

    /// The listing of a source's endpoint, narrowed to the items of its OS.
    func listing(for config: OSSourceConfig) -> Listing {
        var listing = listings[config.listPath] ?? Listing()
        listing.scripts = listing.scripts.filter(config.accepts)
        return listing
    }

    func script(osID: String, scriptID: String) -> ScriptSummary? {
        guard let config = OSSourceConfig.allSources.first(where: { $0.id == osID }) else { return nil }
        return listing(for: config).scripts.first { $0.id == scriptID }
    }

    func loadIfNeeded(_ config: OSSourceConfig, client: GraphClient) async {
        let current = listings[config.listPath] ?? Listing()
        guard !current.hasLoaded, !current.isLoading else { return }
        await reload(config, client: client)
    }

    func reload(_ config: OSSourceConfig, client: GraphClient) async {
        var listing = listings[config.listPath] ?? Listing()
        listing.isLoading = true
        listing.errorMessage = nil
        listings[config.listPath] = listing
        do {
            // Page by page, showing what has arrived: a slow endpoint (apps) fills the sidebar instead of leaving it empty.
            var next: URL? = try client.url(path: config.listPath, query: config.listQuery)
            listing.scripts = []
            while let url = next {
                let page = try await client.page(ScriptSummary.self, url: url)
                listing.scripts = (listing.scripts + page.items.map(\.value))
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                listings[config.listPath] = listing
                next = page.nextLink
            }
            listing.hasLoaded = true
        } catch is CancellationError {
            // Collapsed or switched away; leave it to load again next time.
        } catch {
            listing.errorMessage = error.localizedDescription
        }
        listing.isLoading = false
        listings[config.listPath] = listing
    }

    /// Reads the lists that need no extra permission in the background after sign-in, so the sidebar opens instantly.
    /// Failures are kept in the listing and shown, with Retry, when the section is opened.
    func prefetch(client: GraphClient) async {
        var seen = Set<String>()
        for config in OSSourceConfig.allSources where !config.requiresApps && seen.insert(config.listPath).inserted {
            await loadIfNeeded(config, client: client)
        }
    }

    func reset() {
        listings = [:]
    }
}
