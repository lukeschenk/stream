import SwiftUI

struct JellyfinSettingsView: View {
    let connection: JellyfinConnection
    let profile: AppProfile

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let account = connection.account {
                signedIn(account)
            } else {
                signInForm
            }
        }
        .formStyle(.grouped)
    }

    private func signedIn(_ account: JellyfinAccount) -> some View {
        Section {
            LabeledContent("Server", value: account.serverName ?? account.serverURL.host() ?? "Jellyfin")
            LabeledContent("Address", value: account.serverURL.absoluteString)
            LabeledContent("User", value: account.userName)

            HStack {
                Spacer()
                Button("Sign Out", role: .destructive) {
                    Task {
                        isWorking = true
                        await connection.signOut()
                        isWorking = false
                    }
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Jellyfin")
        } footer: {
            profileNote
        }
    }

    @ViewBuilder
    private var signInForm: some View {
        Section {
            TextField("Server", text: $serverAddress, prompt: Text("http://192.168.1.20:8096"))
            TextField("Username", text: $username)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
        } header: {
            Text("Jellyfin")
        } footer: {
            profileNote
        }

        Section {
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Sign In") {
                    Task { await signIn() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
            }
        }
    }

    private var profileNote: some View {
        Text(
            profile == .kids
                ? "This account is for the Kids profile. Use a Jellyfin user with parental controls."
                : "Each profile signs in separately, so the Kids profile can use its own Jellyfin user."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var canSignIn: Bool {
        !isWorking
            && !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func signIn() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await connection.signIn(
                serverAddress: serverAddress,
                username: username,
                password: password
            )
            password = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
