import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            TextField("Tenant ID", text: $settings.tenantID, prompt: Text("Directory (tenant) ID"))
            TextField("Client ID", text: $settings.clientID, prompt: Text("Application (client) ID"))
            Text("Register http://localhost as a redirect URI under Mobile and desktop applications. The port is chosen automatically at sign-in. No client secret is used.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 480)
    }
}
