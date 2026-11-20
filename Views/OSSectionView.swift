import SwiftUI

/// One OS in the sidebar. Its scripts load the first time it is expanded.
struct OSSectionView: View {
    private struct LoadKey: Hashable {
        let expanded: Bool
        let signedIn: Bool
    }

    let config: OSSourceConfig
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var catalog: ScriptCatalogViewModel
    /// The OS section currently open; opening one closes the others so every section header stays reachable.
    @Binding var expandedOS: String?

    private var isExpanded: Bool { expandedOS == config.id }

    private var expansion: Binding<Bool> {
        Binding(get: { isExpanded }, set: { expandedOS = $0 ? config.id : nil })
    }

    var body: some View {
        let listing = catalog.listing(for: config)
        DisclosureGroup(isExpanded: expansion) {
            if auth.account == nil {
                Text("Sign in first").foregroundStyle(.secondary)
            } else {
                if listing.isLoading { ProgressView().controlSize(.small) }
                if let message = listing.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("Retry") { Task { await reload() } }
                }
                if listing.hasLoaded && listing.scripts.isEmpty {
                    Text("No \(config.itemName) found").foregroundStyle(.secondary)
                }
                ForEach(listing.scripts) { script in
                    ScriptRow(script: script)
                        .tag(SidebarItem.script(osID: config.id, scriptID: script.id))
                }
            }
        } label: {
            Label(config.name, systemImage: config.symbol)
        }
        .task(id: LoadKey(expanded: isExpanded, signedIn: auth.account != nil)) {
            guard isExpanded, auth.account != nil, let configuration = settings.authConfiguration else { return }
            await catalog.loadIfNeeded(config, client: auth.graphClient(config.authConfiguration(configuration)))
        }
    }

    private func reload() async {
        guard let configuration = settings.authConfiguration else { return }
        await catalog.reload(config, client: auth.graphClient(config.authConfiguration(configuration)))
    }
}

private struct ScriptRow: View {
    let script: ScriptSummary

    /// ID and last modified time, kept off the row so long attribute lists stay short and several OS sections fit on screen.
    private var tooltip: String {
        [script.id, script.lastModified.map { $0.formatted(date: .abbreviated, time: .shortened) }]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var body: some View {
        Text(script.title)
            .lineLimit(1)
            .help(tooltip)
    }
}
