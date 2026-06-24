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
                    ForEach(OAuthProvider.allCases, id: \.self) { provider in
                        Button("Continue with \(provider.displayName)") {
                            auth.signIn(provider: provider)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }
}
