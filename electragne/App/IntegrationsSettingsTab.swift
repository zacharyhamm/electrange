//
//  IntegrationsSettingsTab.swift
//  electragne
//
//  Settings › Integrations: SOCKS5 proxy, Slack (dobbs), Linear, and
//  Google account management.
//

import SwiftUI

struct IntegrationsSettingsTab: View {
    @AppStorage(UserPreferences.socksProxyEndpointKey)
    private var socksProxyEndpoint = UserPreferences.defaultSOCKSProxyEndpoint

    @AppStorage(UserPreferences.dobbsEndpointKey) private var dobbsEndpoint = ""
    @AppStorage(UserPreferences.dobbsWorkspaceKey) private var dobbsWorkspace = ""
    @AppStorage(UserPreferences.dobbsUseProxyKey) private var dobbsUseProxy = false
    @State private var dobbsToken = ""
    @State private var dobbsStatus = SaveStatus()

    @State private var linearAPIKey = ""
    @State private var linearStatus = SaveStatus()

    @AppStorage(GoogleOAuthService.clientIDKey) private var googleClientID = ""
    @State private var googleClientSecret = ""
    @State private var googleAccounts: [GoogleAccount] = []
    @State private var defaultGoogleAccountID: String?
    @State private var googleError: String?
    @State private var googleBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Tailscale SOCKS5 proxy")
                        .font(.headline)
                    Text("The sidecar tailscaled's SOCKS5 proxy. Endpoints with \"Route via Tailscale proxy\" enabled connect through it to reach tailnet devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(UserPreferences.defaultSOCKSProxyEndpoint, text: $socksProxyEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Slack (dobbs)")
                            .font(.headline)
                        Spacer()
                        Button("Save Token") {
                            dobbsStatus = saveKeychainKey(
                                $dobbsToken, for: .dobbs,
                                removalHint: "Clear the field and save to remove the token."
                            )
                        }
                    }
                    Text("Lets the pet search and summarize Slack through a running dobbs daemon. The token is stored in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Endpoint")
                        .font(.subheadline.weight(.medium))
                    TextField("host:port, e.g. 127.0.0.1:7355", text: $dobbsEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Toggle("Route via Tailscale proxy", isOn: $dobbsUseProxy)

                    Text("Workspace")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    TextField("Optional expected workspace name", text: $dobbsWorkspace)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Text("When set, tool calls fail unless the daemon serves this workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Token")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    SecureField("Paste the dobbs daemon token", text: $dobbsToken)
                        .textFieldStyle(.roundedBorder)

                    if let message = dobbsStatus.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(dobbsStatus.failed ? .red : .secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Linear")
                            .font(.headline)
                        Spacer()
                        Button("Save Key") {
                            linearStatus = saveKeychainKey(
                                $linearAPIKey, for: .linear,
                                removalHint: "Clear the field and save to remove the key."
                            )
                        }
                    }
                    Text("Lets the pet search, read, and create Linear issues. The API key is stored in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline) {
                        Text("API key")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 12)
                        Link("Create one in Linear", destination: URL(string: "https://linear.app/settings/account/security")!)
                            .font(.caption)
                    }
                    SecureField("Paste your Linear personal API key", text: $linearAPIKey)
                        .textFieldStyle(.roundedBorder)

                    if let message = linearStatus.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(linearStatus.failed ? .red : .secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Google accounts")
                            .font(.headline)
                        Spacer()
                        if googleBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Connect Account…", action: connectGoogleAccount)
                            .disabled(googleBusy || googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Connect Gmail and Google Calendar with one Google account authorization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !googleAccounts.isEmpty {
                        Text("Already connected? Reconnect once to approve the new Calendar permissions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Client ID")
                            .font(.subheadline.weight(.medium))
                        TextField("…apps.googleusercontent.com", text: $googleClientID)
                            .textFieldStyle(.roundedBorder)

                        Text("Client secret")
                            .font(.subheadline.weight(.medium))
                            .padding(.top, 3)
                        SecureField("Paste the desktop client secret", text: $googleClientSecret)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Use credentials from a Desktop OAuth client. The secret is saved in Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            .font(.caption)
                    }

                    if googleAccounts.isEmpty {
                        Text("No Google accounts connected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    } else {
                        ForEach(googleAccounts) { account in
                            HStack(spacing: 9) {
                                Button {
                                    GoogleOAuthService.shared.setDefaultAccount(id: account.id)
                                    refreshGoogleAccounts()
                                } label: {
                                    Image(systemName: account.id == defaultGoogleAccountID ? "largecircle.fill.circle" : "circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Use \(account.email) by default")

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.email)
                                        .lineLimit(1)
                                    if let name = account.displayName, !name.isEmpty {
                                        Text(name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Menu {
                                    Button("Reconnect…", action: connectGoogleAccount)
                                    Button("Disconnect", role: .destructive) {
                                        disconnectGoogleAccount(account)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .disabled(googleBusy)
                                .accessibilityLabel("Actions for \(account.email)")
                            }
                        }
                    }

                    if let googleError {
                        Text(googleError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .onAppear {
            dobbsToken = ChatAPIKeyStore.key(for: .dobbs) ?? ""
            linearAPIKey = ChatAPIKeyStore.key(for: .linear) ?? ""
            googleClientSecret = GoogleOAuthService.shared.clientSecret
            refreshGoogleAccounts()
        }
    }

    private func refreshGoogleAccounts() {
        googleAccounts = GoogleOAuthService.shared.accounts
        defaultGoogleAccountID = GoogleOAuthService.shared.defaultAccountID
    }

    private func connectGoogleAccount() {
        guard let window = NSApp.keyWindow else {
            googleError = "The Settings window is not available for Google sign-in."
            return
        }
        GoogleOAuthService.shared.clientID = googleClientID
        GoogleOAuthService.shared.clientSecret = googleClientSecret
        googleBusy = true
        googleError = nil
        Task {
            defer { googleBusy = false }
            do {
                _ = try await GoogleOAuthService.shared.connect(presenting: window)
                refreshGoogleAccounts()
            } catch {
                googleError = error.localizedDescription
            }
        }
    }

    private func disconnectGoogleAccount(_ account: GoogleAccount) {
        googleBusy = true
        googleError = nil
        Task {
            defer { googleBusy = false }
            do {
                try await GoogleOAuthService.shared.disconnect(accountID: account.id)
                refreshGoogleAccounts()
            } catch {
                googleError = error.localizedDescription
            }
        }
    }
}
