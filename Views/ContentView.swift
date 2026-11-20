import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var catalog = ScriptCatalogViewModel()
    @StateObject private var upnSearch = DeviceSearchViewModel(mode: .upn, cache: .shared)
    @StateObject private var deviceSearch = DeviceSearchViewModel(mode: .device, cache: .shared)
    @State private var selection: SidebarItem? = .account

    var body: some View {
        Group {
            if auth.account == nil {
                SignInView()
            } else {
                tool
            }
        }
        .frame(minWidth: auth.account == nil ? 480 : 900, minHeight: auth.account == nil ? 320 : 520)
        .background(WindowReveal())
        .background(WindowSize(size: auth.account == nil ? CGSize(width: 480, height: 320) : CGSize(width: 1000, height: 640)))
        .task(id: auth.account) {
            if auth.account == nil {
                ResultsWarmup.shared.cancel()
                ResultsCache.shared.clear()
                catalog.reset()
                Task { await DeviceInventory.shared.reset() }
                upnSearch.reset()
                deviceSearch.reset()
                selection = .account
            } else if let configuration = settings.authConfiguration {
                let client = auth.graphClient(configuration)
                await catalog.prefetch(client: client)
                _ = try? await DeviceInventory.shared.devices(client: client)
                warmUp(configuration)
            }
        }
    }

    /// Reads the items opened most recently in the background, so they are ready when opened again.
    private func warmUp(_ configuration: AuthConfiguration) {
        let recent = RecentItems().items.compactMap { entry -> (config: OSSourceConfig, script: ScriptSummary)? in
            guard let config = OSSourceConfig.allSources.first(where: { $0.id == entry.sourceID }),
                  let script = catalog.script(osID: entry.sourceID, scriptID: entry.itemID) else { return nil }
            return (config, script)
        }
        ResultsWarmup.shared.start(items: recent) { auth.graphClient($0.authConfiguration(configuration)) }
    }

    private var tool: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            VStack(spacing: 0) {
                banner
                detail
            }
        }
        .environmentObject(catalog)
    }

    /// The logo sits at the right edge of the picture, so a narrow window crops the left side, never the logo.
    private var banner: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .overlay(alignment: .trailing) {
                Image("Banner").resizable().scaledToFill()
            }
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .script(let osID, let scriptID)?:
            if let config = OSSourceConfig.allSources.first(where: { $0.id == osID }),
               let script = catalog.script(osID: osID, scriptID: scriptID) {
                AttributeResultsView(config: config, script: script).id(scriptID)
            } else {
                Text("Select an attribute in the sidebar.").foregroundStyle(.secondary)
            }
        case .upnSearch?:
            DeviceSearchView(model: upnSearch).id(SidebarItem.upnSearch)
        case .deviceSearch?:
            DeviceSearchView(model: deviceSearch).id(SidebarItem.deviceSearch)
        default:
            AccountView()
        }
    }
}
