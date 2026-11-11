import SwiftUI

struct JellyfinSettingsView: View {
    let connection: JellyfinConnection
    let profile: AppProfile

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var quickConnect: JellyfinQuickConnectRequest?
    @State private var quickConnectTask: Task<Void, Never>?
    @State private var approvalCode = ""
    @State private var approvalMessage: String?

    var body: some View {
        Form {
            if let account = connection.account {
                signedIn(account)
                approveDevice
            } else {
                signInForm
                codeSignIn
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: fillInSuggestion)
        .onChange(of: connection.suggestion) { fillInSuggestion() }
        .onDisappear { cancelQuickConnect() }
    }

    private func fillInSuggestion() {
        guard let suggestion = connection.suggestion else { return }
        if serverAddress.isEmpty {
            serverAddress = suggestion.serverAddress
        }
        if username.isEmpty {
            username = suggestion.userName
        }
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
                    ProgressView()
                    #if os(macOS)
                        .controlSize(.small)
                    #endif
                }
                Button("Sign In") {
                    Task { await signIn() }
                }
                #if !os(tvOS)
                .keyboardShortcut(.defaultAction)
                #endif
                .disabled(!canSignIn)
            }
        }
    }

    // MARK: Quick Connect

    @ViewBuilder
    private var codeSignIn: some View {
        Section {
            if let quickConnect {
                VStack(alignment: .leading, spacing: 8) {
                    Text(quickConnect.code)
                        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    #if !os(tvOS)
                        .textSelection(.enabled)
                    #endif
                    Text("Waiting for approval…")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { cancelQuickConnect() }
            } else {
                Button("Sign In with a Code") { startQuickConnect() }
                    .disabled(isWorking || JellyfinClient.serverURL(from: serverAddress) == nil)
            }
        } header: {
            Text("Sign In with a Code")
        } footer: {
            Text(
                "No password needed. Approve the code in Stream on a device that’s signed in "
                    + "(Settings → Jellyfin), or in Jellyfin under your profile → Quick Connect."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var approveDevice: some View {
        Section {
            TextField("Code", text: $approvalCode, prompt: Text("123456"))
            Button("Approve") {
                Task { await approve() }
            }
            .disabled(isWorking || approvalCode.filter(\.isNumber).count < 6)

            if let approvalMessage {
                Text(approvalMessage)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Approve a Device")
        } footer: {
            Text("On your Apple TV or another device, choose Sign In with a Code, then enter the code here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func startQuickConnect() {
        errorMessage = nil
        isWorking = true
        quickConnectTask = Task {
            defer {
                isWorking = false
                quickConnect = nil
            }
            do {
                let request = try await connection.beginQuickConnect(serverAddress: serverAddress)
                quickConnect = request
                try await connection.completeQuickConnect(request)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnect = nil
    }

    private func approve() async {
        isWorking = true
        approvalMessage = nil
        defer { isWorking = false }

        do {
            try await connection.approveQuickConnect(code: approvalCode)
            approvalMessage = "Approved. The other device is signing in."
            approvalCode = ""
        } catch {
            approvalMessage = error.localizedDescription
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
