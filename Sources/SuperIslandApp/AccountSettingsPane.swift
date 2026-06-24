import SwiftUI
import SuperIslandCore

struct AccountSettingsPane: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        Form {
            if let session = auth.session {
                Section("Signed in") {
                    LabeledContent("Account", value: session.email ?? "—")
                    Button("Sign out") { auth.signOut() }
                }
            } else {
                Section("Sign in to use SuperIsland") {
                    VStack(spacing: 10) {
                        ForEach(OAuthProvider.allCases, id: \.self) { provider in
                            ProviderSignInButton(provider: provider) {
                                auth.signIn(provider: provider)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }
}
