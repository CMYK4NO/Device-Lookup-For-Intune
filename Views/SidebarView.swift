import SwiftUI

enum SidebarItem: Hashable {
    case account
    case upnSearch
    case deviceSearch
    case script(osID: String, scriptID: String)
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @State private var expandedOS: String?

    var body: some View {
        List(selection: $selection) {
            Section("General") {
                Label("Account", systemImage: "person.crop.circle")
                    .tag(SidebarItem.account)
            }
            Section("Search") {
                Label("UPN", systemImage: "magnifyingglass")
                    .tag(SidebarItem.upnSearch)
                Label("Device", systemImage: "laptopcomputer")
                    .tag(SidebarItem.deviceSearch)
            }
            section("Compliance", OSSourceConfig.complianceSources)
            section("Configurations", OSSourceConfig.configurationSources)
            section("Managed Apps", OSSourceConfig.appSources)
            section("Attributes", OSSourceConfig.all)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }

    private func section(_ title: String, _ sources: [OSSourceConfig]) -> some View {
        Section(title) {
            ForEach(sources) { OSSectionView(config: $0, expandedOS: $expandedOS) }
        }
    }
}
