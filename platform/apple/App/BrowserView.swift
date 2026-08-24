import SwiftUI
import WebKit

@available(iOS 26.0, macOS 26.0, *)
@MainActor
struct BrowserView: View {
    @State private var workspace = BrowserWorkspace()
    @State private var firefoxSync: FirefoxSyncViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(firefoxSyncProcess: XanhFirefoxSyncProcessService) {
        _firefoxSync = State(
            initialValue: FirefoxSyncViewModel(process: firefoxSyncProcess)
        )
    }

    var body: some View {
        let tab = workspace.selectedTab

        VStack(spacing: 0) {
            navigationBar(for: tab)
            if tab.page.isLoading {
                ProgressView(value: tab.page.estimatedProgress)
                    .progressViewStyle(.linear)
            }
            WebView(tab.page)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewLinkPreviews(.enabled)
                .webViewTextSelection(.enabled)
                .webViewElementFullscreenBehavior(.enabled)
        }
        .browserWindowMinimumSize()
        .onChange(of: tab.page.url) { _, newURL in
            firefoxSync.clearCredentialLibrary()
            if let newURL, AddressResolver.isAllowedWebURL(newURL) {
                tab.address = newURL.absoluteString
                workspace.persistSession()
            }
        }
        .onChange(of: workspace.selectedTabID) { _, _ in
            firefoxSync.cancelCredentialSelection()
            firefoxSync.clearCredentialLibrary()
            workspace.persistSession()
            workspace.selectedTab.recoverPendingWebContentProcessIfPossible(
                isForeground: scenePhase == .active
            )
        }
        .onChange(of: firefoxSync.snapshot.vaultUnlocked) { _, unlocked in
            guard !unlocked else { return }
            firefoxSync.cancelCredentialSelection()
            firefoxSync.clearCredentialLibrary(detail: "Password vault locked.")
        }
        .onChange(of: tab.externalURL) { _, externalURL in
            guard let externalURL else { return }
            openURL(externalURL)
            tab.externalURL = nil
        }
        .onChange(of: tab.adblockInstallationPending) { _, pending in
            if !pending {
                tab.recoverPendingWebContentProcessIfPossible(
                    isForeground: scenePhase == .active
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                tab.recoverPendingWebContentProcessIfPossible(isForeground: true)
            } else {
                tab.cancelInFlightWebContentRecoveryForBackground()
            }
            Task {
                if phase == .active { await firefoxSync.syncIfDue(.startup) }
                else {
                    firefoxSync.cancelCredentialSelection()
                    firefoxSync.clearCredentialLibrary()
                    await firefoxSync.lockVault()
                }
            }
        }
        .onOpenURL { url in
            Task { await firefoxSync.handleOAuthCallback(url) }
        }
        .sheet(isPresented: $firefoxSync.isShowingSettings) {
            FirefoxSyncSettingsView(
                model: firefoxSync,
                isPrivateContext: tab.isPrivate,
                canSaveCurrentPage: !tab.isPrivate
                    && tab.page.url.map(XanhPlacesPolicy.isAllowedWebURL) == true,
                onSaveCurrentBookmark: {
                    Task {
                        await firefoxSync.saveBookmark(
                            url: tab.page.url,
                            title: tab.page.title,
                            isPrivate: tab.isPrivate
                        )
                    }
                },
                onOpenLibraryURL: { url in
                    guard XanhPlacesPolicy.isAllowedWebURL(url) else { return }
                    _ = workspace.addTab(initialURL: url)
                },
                credentialContextProvider: {
                    guard let documentURL = tab.page.url else { return nil }
                    return XanhCredentialContext.exactTopLevel(
                        documentURL: documentURL,
                        isPrivate: tab.isPrivate,
                        userSelected: true
                    )
                }
            )
        }
        .sheet(item: $firefoxSync.credentialSelection, onDismiss: {
            firefoxSync.cancelCredentialSelection()
        }) { selection in
            FirefoxCredentialPickerView(model: firefoxSync, selection: selection)
        }
        .task {
            await firefoxSync.initializeIfConfigured()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await firefoxSync.lockVaultIfIdle()
                await firefoxSync.syncIfDue(.scheduled)
            }
        }
        .task(
            id: NavigationObservationID(
                tabID: tab.id,
                generation: tab.navigationObservationGeneration
            )
        ) {
            tab.credentialRequestHandler = { [weak firefoxSync] context in
                await firefoxSync?.requestCredential(for: context)
            }
            do {
                for try await event in tab.page.navigations {
                    tab.handleNavigationEvent(event)
                    if event == .finished,
                       let url = tab.page.url,
                       XanhPlacesPolicy.isAllowedWebURL(url) {
                        await firefoxSync.recordHistory(
                            url: url,
                            title: tab.page.title,
                            isPrivate: tab.isPrivate
                        )
                    }
                }
            } catch {
                firefoxSync.cancelCredentialSelection()
                tab.handleNavigationError(error, isForeground: scenePhase == .active)
            }
        }
        .alert(
            "Navigation blocked",
            isPresented: Binding(
                get: { tab.errorMessage != nil },
                set: { if !$0 { tab.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tab.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func navigationBar(for tab: BrowserTab) -> some View {
        @Bindable var tab = tab
        @Bindable var workspace = workspace

        HStack(spacing: 10) {
            Button("Back", systemImage: "chevron.left") { tab.goBack() }
                .labelStyle(.iconOnly)
                .disabled(
                    tab.adblockInstallationPending ||
                        tab.page.backForwardList.backList.isEmpty
                )
            Button("Forward", systemImage: "chevron.right") { tab.goForward() }
                .labelStyle(.iconOnly)
                .disabled(
                    tab.adblockInstallationPending ||
                        tab.page.backForwardList.forwardList.isEmpty
                )
            Button("Reload", systemImage: "arrow.clockwise") { tab.reload() }
                .labelStyle(.iconOnly)
                .disabled(tab.adblockInstallationPending)

            TextField("Search or enter website", text: $tab.address)
                .textFieldStyle(.roundedBorder)
                .disabled(tab.adblockInstallationPending)
                .onSubmit { tab.submitAddress { openURL($0) } }

            Menu {
                Picker("Tabs", selection: $workspace.selectedTabID) {
                    ForEach(workspace.tabs) { candidate in
                        Text(candidate.page.title.isEmpty ? candidate.address : candidate.page.title)
                            .tag(candidate.id)
                    }
                }
                Divider()
                if tab.adblockOperational {
                    Toggle("Block ads and trackers", isOn: $workspace.adblockEnabled)
                        .help("Applies to subsequent page loads.")
                } else {
                    Toggle("Content blocking unavailable", isOn: .constant(false))
                        .disabled(true)
                        .help("Restart Xanh Browser to retry the bundled content rule list.")
                }
                Button("New Tab", systemImage: "plus") { workspace.addTab() }
                Button("New Private Tab", systemImage: "hand.raised") { workspace.addTab(isPrivate: true) }
                Button("Close Tab", systemImage: "xmark") {
                    firefoxSync.cancelCredentialSelection()
                    workspace.closeSelectedTab()
                }
                    .disabled(workspace.tabs.count == 1)
            } label: {
                Label("Tabs", systemImage: tab.isPrivate ? "hand.raised.fill" : "square.on.square")
            }

            if let currentURL = tab.page.url {
                ShareLink(item: currentURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
            } else {
                Button("Share", systemImage: "square.and.arrow.up") {}
                    .labelStyle(.iconOnly)
                    .disabled(true)
            }

            Button("Firefox Sync", systemImage: syncIcon) {
                firefoxSync.isShowingSettings = true
            }
            .labelStyle(.iconOnly)
            .help(firefoxSync.snapshot.detail)
        }
        .padding(10)
        .background(.bar)
    }

    private var syncIcon: String {
        switch firefoxSync.snapshot.accountState {
        case .connected: "arrow.triangle.2.circlepath.circle.fill"
        case .authIssues: "exclamationmark.arrow.triangle.2.circlepath"
        case .authenticating: "person.badge.clock"
        case .disconnected: "arrow.triangle.2.circlepath.circle"
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@MainActor
private struct FirefoxCredentialPickerView: View {
    let model: FirefoxSyncViewModel
    let selection: FirefoxCredentialSelection

    var body: some View {
        NavigationStack {
            List(selection.credentials) { record in
                Button {
                    Task { await model.selectCredential(record) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.username.isEmpty ? "(empty username)" : record.username)
                        Text(selection.context.documentURL.host ?? "Secure website")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Choose a saved login")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelCredentialSelection() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 280)
    }
}

private struct NavigationObservationID: Hashable {
    let tabID: UUID
    let generation: Int
}

private extension View {
    @ViewBuilder
    func browserWindowMinimumSize() -> some View {
#if os(macOS)
        frame(minWidth: 640, minHeight: 480)
#else
        self
#endif
    }
}
