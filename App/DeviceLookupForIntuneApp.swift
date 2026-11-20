import SwiftUI

@main
struct DeviceLookupForIntuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    @StateObject private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(auth)
        }
        .windowResizability(.contentMinSize)
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
