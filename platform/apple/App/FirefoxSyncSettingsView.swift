import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
struct FirefoxSyncSettingsView: View {
    @Bindable var model: FirefoxSyncViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Text(model.snapshot.detail)
                    if let lastSync = model.snapshot.lastSync {
                        LabeledContent("Last sync", value: lastSync.formatted())
                    }
                    if let nextAllowed = model.snapshot.nextAllowed {
                        LabeledContent("Server backoff until", value: nextAllowed.formatted())
                    }
                }

                if !model.isConfigured {
                    Section("Self-hosted Firefox Sync") {
                        Text("Use the same HTTPS Accounts and Token Server deployment configured in Firefox. Mozilla-hosted sign-in is enabled only in an approved production build.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("Accounts URL", text: $model.accountsURL)
                            .textContentType(.URL)
                        TextField("Token Server URL", text: $model.tokenServerURL)
                            .textContentType(.URL)
                        TextField("Client ID", text: $model.clientID)
                        Button("Save configuration") {
                            Task { await model.saveSelfHostedConfiguration() }
                        }
                    }
                } else {
                    Section("Account") {
                        switch model.snapshot.accountState {
                        case .connected:
                            Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                                Task { await model.syncNow() }
                            }
                        case .authenticating:
                            Text("Finish sign-in in the system browser.")
                        case .disconnected, .authIssues:
                            Button("Sign in with Firefox Accounts", systemImage: "person.crop.circle") {
                                Task { await model.prepareSignIn() }
                            }
                        }
                    }

                    if model.snapshot.accountState == .connected {
                        Section("This device") {
                            ForEach(XanhSyncEngine.allCases, id: \.self) { engine in
                                Toggle(
                                    engineLabel(engine),
                                    isOn: Binding(
                                        get: { model.snapshot.enabledEngines.contains(engine) },
                                        set: { enabled in
                                            Task { await model.setEngine(engine, enabled: enabled) }
                                        }
                                    )
                                )
                            }
                        }

                        Section("Passwords") {
                            Button(
                                model.snapshot.vaultUnlocked ? "Lock password vault" : "Unlock password vault",
                                systemImage: model.snapshot.vaultUnlocked ? "lock" : "lock.open"
                            ) {
                                Task { await model.toggleVault() }
                            }
                            Text("The vault locks after five minutes idle and whenever Xanh Browser goes to the background.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Section("Tabs from other devices") {
                            Text(model.remoteTabsSummary)
                            Button("Refresh remote tabs") {
                                Task { await model.loadRemoteTabs() }
                            }
                        }

                        Section {
                            Button("Disconnect", role: .destructive) {
                                model.isConfirmingDisconnect = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("Firefox Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Open Firefox Accounts?", isPresented: $model.isConfirmingAccountDomain) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                if let url = model.confirmedSignInURL() { openURL(url) }
            }
        } message: {
            Text("Xanh Browser will continue sign-in at \(model.accountDomain) in the system browser. TLS errors cannot be bypassed.")
        }
        .alert(
            "Firefox Sync error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Disconnect Firefox Sync",
            isPresented: $model.isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Keep local data") { Task { await model.disconnect(deleteLocal: false) } }
            Button("Remove from this device", role: .destructive) {
                Task { await model.disconnect(deleteLocal: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing local data deletes Places, Logins, Tabs, Sync metadata and the device-only vault key.")
        }
    }

    private func engineLabel(_ engine: XanhSyncEngine) -> String {
        switch engine {
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .tabs: "Tabs"
        case .passwords: "Passwords"
        }
    }
}
