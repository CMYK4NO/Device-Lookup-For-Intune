import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account").font(.title2)

            if let account = auth.account {
                Form {
                    LabeledContent("Name", value: account.name)
                    LabeledContent("User", value: account.username)
                }
                .textSelection(.enabled)
                Button("Sign out", role: .destructive) { auth.signOut() }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
