import SwiftUI

/// Shown over the app for a couple of seconds at launch.
struct SplashView: View {
    var body: some View {
        Image("Splash")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
    }
}
