#if !os(tvOS)
    import AuthenticationServices
#endif
import SwiftUI

struct TraktSettingsView: View {
    let connection: TraktConnection
    let watchlist: WatchlistStore

    #if !os(tvOS)
        @Environment(\.webAuthenticationSession)
        private var webAuthenticationSession
    #endif
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var deviceCode: TraktDeviceCode?
    @State private var deviceTask: Task<Void, Never>?

    var body: some View {
        Form {
            if !connection.isAvailable {
                Section {
                    Text(
                        "This build has no Trakt Client ID. Add TRAKT_CLIENT_ID to Config/Secrets.xcconfig "
                            + "to sign in and bring in your watch history."
                    )
                    .foregroundStyle(.secondary)
                }
            } else if connection.isSignedIn {
                signedIn
            } else {
                signIn
            }
        }
        .formStyle(.grouped)
        .onDisappear { cancelDeviceSignIn() }
    }

    // MARK: Signed in

    private var signedIn: some View {
        Section {
            LabeledContent("Account", value: connection.username ?? "Signed in")
            LabeledContent("Last Synced", value: lastSyncedText)

            if let syncError = connection.syncError {
                Text(syncError)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Sync Now") {
                    Task { await connection.syncHistory(into: watchlist, force: true) }
                }
                .disabled(connection.isSyncing)

                if connection.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }

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
            Text("Trakt")
        } footer: {
            Text(
                "The latest episode you’ve watched of each show becomes where to pick up. Shows you "
                    + "watched in the last month are added to the watchlist."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var lastSyncedText: String {
        guard let date = connection.lastSyncedAt else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    // MARK: Signing in

    @ViewBuilder
    private var signIn: some View {
        #if !os(tvOS)
            Section {
                Button("Sign In with Trakt") {
                    Task { await signInWithBrowser() }
                }
                .disabled(isWorking || deviceCode != nil)
            } header: {
                Text("Trakt")
            } footer: {
                Text("Brings in what you’ve watched so Stream knows where to pick up each show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        #endif

        codeSignIn

        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var codeSignIn: some View {
        Section {
            if let deviceCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(deviceCode.userCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    #if !os(tvOS)
                        .textSelection(.enabled)
                    #endif
                    Text("Go to \(deviceCode.verificationURL.absoluteString) and enter this code.")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { cancelDeviceSignIn() }
            } else {
                Button("Sign In with a Code") { startDeviceSignIn() }
                    .disabled(isWorking)
            }
        } header: {
            Text("Sign In with a Code")
        } footer: {
            Text("Approve the code on your phone or computer at trakt.tv/activate.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    #if !os(tvOS)
        private func signInWithBrowser() async {
            guard let request = connection.beginWebSignIn() else { return }
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }

            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: request.url,
                    callback: .customScheme(TraktAuthClient.callbackScheme),
                    additionalHeaderFields: [:]
                )
                try await connection.completeWebSignIn(request, callback: callback)
                await connection.syncHistory(into: watchlist, force: true)
            } catch ASWebAuthenticationSessionError.canceledLogin {
                return
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    #endif

    private func startDeviceSignIn() {
        cancelDeviceSignIn()
        errorMessage = nil
        deviceTask = Task {
            do {
                guard let code = try await connection.beginDeviceSignIn() else { return }
                deviceCode = code
                try await connection.completeDeviceSignIn(code)
                deviceCode = nil
                await connection.syncHistory(into: watchlist, force: true)
            } catch is CancellationError {
                return
            } catch {
                deviceCode = nil
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func cancelDeviceSignIn() {
        deviceTask?.cancel()
        deviceTask = nil
        deviceCode = nil
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TraktAuthError.denied: "Trakt sign-in was declined."
        case TraktAuthError.expired: "The code expired. Try again."
        case TraktAuthError.stateMismatch, TraktAuthError.invalidCallback: "Trakt sent back an unexpected reply."
        case let TraktAuthError.server(statusCode):
            "Trakt couldn’t sign you in (error \(statusCode)). Check the Client ID and redirect URI."
        default: "Couldn’t sign in to Trakt. \(error.localizedDescription)"
        }
    }
}
