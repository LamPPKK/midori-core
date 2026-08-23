import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
@MainActor
struct FirefoxSyncSettingsView: View {
    @Bindable var model: FirefoxSyncViewModel
    let isPrivateContext: Bool
    let canSaveCurrentPage: Bool
    let onSaveCurrentBookmark: () -> Void
    let onOpenLibraryURL: (URL) -> Void
    let credentialContextProvider: @MainActor @Sendable () -> XanhCredentialContext?
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

                        FirefoxPlacesSettingsSection(
                            model: model,
                            isPrivateContext: isPrivateContext,
                            canSaveCurrentPage: canSaveCurrentPage,
                            onSaveCurrentBookmark: onSaveCurrentBookmark,
                            onOpenLibraryURL: onOpenLibraryURL
                        )

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
                            NavigationLink {
                                FirefoxPasswordsLibraryView(
                                    model: model,
                                    contextProvider: credentialContextProvider
                                )
                            } label: {
                                Label("Passwords for Current Site", systemImage: "key")
                            }
                            .disabled(credentialContextProvider()?.isAllowed != true)
                        }

                        Section("Tabs from other devices") {
                            Text(model.remoteTabsStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(model.remoteTabs) { device in
                                DisclosureGroup {
                                    ForEach(device.tabs) { tab in
                                        Button {
                                            guard let url = tab.currentURL,
                                                  AddressResolver.isAllowedWebURL(url) else { return }
                                            onOpenLibraryURL(url)
                                            dismiss()
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack {
                                                    Text(tab.displayTitle)
                                                        .lineLimit(1)
                                                    if tab.isPinned {
                                                        Image(systemName: "pin.fill")
                                                            .accessibilityLabel("Pinned")
                                                    }
                                                }
                                                if let url = tab.currentURL {
                                                    Text(url.absoluteString)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                                Text(lastUsedLabel(tab.lastUsedEpochMillis))
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } label: {
                                    Label(
                                        "\(device.displayName) (\(device.tabs.count))",
                                        systemImage: deviceIcon(device.kind)
                                    )
                                }
                            }
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
                Task {
                    guard let url = await model.beginConfirmedSignIn() else { return }
                    openURL(url) { accepted in
                        Task { await model.finishOAuthLaunch(accepted: accepted) }
                    }
                }
            }
        } message: {
            Text("Xanh Browser will continue sign-in at \(model.accountOrigin) in the system browser. TLS errors cannot be bypassed.")
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

    private func deviceIcon(_ kind: XanhRemoteDeviceKind) -> String {
        switch kind {
        case .desktop: "desktopcomputer"
        case .mobile: "iphone"
        case .tablet: "ipad"
        case .tv: "tv"
        case .vr: "visionpro"
        case .unknown: "questionmark.square"
        }
    }

    private func lastUsedLabel(_ epochMillis: Int64) -> String {
        guard epochMillis > 0 else { return "Last used time unavailable" }
        return Date(timeIntervalSince1970: Double(epochMillis) / 1_000).formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct FirefoxPlacesSettingsSection: View {
    @Bindable var model: FirefoxSyncViewModel
    let isPrivateContext: Bool
    let canSaveCurrentPage: Bool
    let onSaveCurrentBookmark: () -> Void
    let onOpenLibraryURL: (URL) -> Void

    var body: some View {
        Section("Places library") {
            if isPrivateContext {
                Text("Places changes are unavailable while the current tab is private.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Bookmark current page", systemImage: "bookmark") {
                onSaveCurrentBookmark()
            }
            .disabled(!canSaveCurrentPage)
            NavigationLink {
                FirefoxBookmarksLibraryView(
                    model: model,
                    isPrivateContext: isPrivateContext,
                    onOpenURL: onOpenLibraryURL
                )
            } label: {
                Label("Bookmarks", systemImage: "book")
            }
            NavigationLink {
                FirefoxHistoryLibraryView(
                    model: model,
                    isPrivateContext: isPrivateContext,
                    onOpenURL: onOpenLibraryURL
                )
            } label: {
                Label("History", systemImage: "clock")
            }
        }
    }
}
