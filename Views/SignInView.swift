import SwiftUI

/// Shown until an account is signed in; the tool itself stays hidden behind it.
struct SignInView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Sign in with your administrator account").font(.title3)

            if auth.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in in your browser…")
                }
                Button("Cancel") { auth.cancelSignIn() }
            } else {
                Button("Sign in with Microsoft", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.authConfiguration == nil)
                if settings.authConfiguration == nil {
                    Text("An administrator must first enter the Tenant ID and Client ID of the Entra app registration in Settings (⌘,).")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = auth.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        if let configuration = settings.authConfiguration { auth.beginSignIn(configuration) }
    }
}
