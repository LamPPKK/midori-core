import Foundation
import Observation
import WebKit

@available(iOS 26.0, macOS 26.0, *)
final class BrowserNavigationPolicy: WebPage.NavigationDeciding {
    var onOpenExternalURL: ((URL) -> Void)?
    var onExplicitUserWebNavigation: (() -> Void)?
    var isNavigationTemporarilyBlocked: (() -> Bool)?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        guard isNavigationTemporarilyBlocked?() != true else { return .cancel }
        preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        #if os(macOS)
        let hasTrustedButtonActivation = action.buttonNumber >= 0
        #else
        let hasTrustedButtonActivation = !action.buttonNumber.isEmpty
        #endif
        let isTrustedMainFrameLinkActivation = action.navigationType == .linkActivated
            && action.source.isMainFrame
            && (action.target?.isMainFrame ?? true)
            && hasTrustedButtonActivation
            && !action.isContentRuleListRedirect
        if ExternalNavigationPolicy.allows(
            url: url,
            isLinkActivated: action.navigationType == .linkActivated,
            sourceIsMainFrame: action.source.isMainFrame,
            targetIsMainFrameOrNewWindow: action.target?.isMainFrame ?? true,
            hasTrustedButtonActivation: hasTrustedButtonActivation,
            isContentRuleListRedirect: action.isContentRuleListRedirect
        ) {
            onOpenExternalURL?(url)
            return .cancel
        }
        guard AddressResolver.isAllowedWebURL(url) else { return .cancel }
        if isTrustedMainFrameLinkActivation {
            onExplicitUserWebNavigation?()
        }
        return action.shouldPerformDownload ? .download : .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        guard let url = response.response.url, AddressResolver.isAllowedWebURL(url) else {
            return .cancel
        }
        return response.canShowMimeType ? .allow : .download
    }
}

@available(iOS 26.0, macOS 26.0, *)
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let page: WebPage
    let isPrivate: Bool
    var address: String
    var errorMessage: String?
    var externalURL: URL?
    var adblockOperational = true
    var adblockInstallationPending = false
    var navigationObservationGeneration = 0
    var credentialRequestHandler: ((XanhCredentialContext) async -> XanhCredentialRecord?)?

    @ObservationIgnored
    private let credentialBridge: BrowserCredentialBridge?
    @ObservationIgnored
    private let userContentController: WKUserContentController
    @ObservationIgnored
    private var installedAdblockRuleList: WKContentRuleList?
    @ObservationIgnored
    private var adblockUpdateGeneration = 0
    @ObservationIgnored
    private var pendingInitialURL: URL?
    @ObservationIgnored
    private var credentialNavigation: (nonce: String, documentURL: URL)?
    @ObservationIgnored
    private var credentialRequestRunning = false
    @ObservationIgnored
    private var processRecovery = WebContentProcessRecoveryPolicy()

    init(
        isPrivate: Bool = false,
        initialURL: URL = AddressResolver.defaultHomePage,
        adblockEnabled: Bool = true
    ) {
        self.isPrivate = isPrivate
        self.address = initialURL.absoluteString
        self.pendingInitialURL = initialURL

        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.deviceSensorAuthorization = .init(decision: .prompt)
        configuration.applicationNameForUserAgent = "XanhBrowser/1.0"
        configuration.upgradeKnownHostsToHTTPS = true
        let bridge = isPrivate ? nil : BrowserCredentialBridge()
        let userContentController = bridge?.userContentController ?? WKUserContentController()
        configuration.userContentController = userContentController
        self.credentialBridge = bridge
        self.userContentController = userContentController
        let navigationPolicy = BrowserNavigationPolicy()
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: navigationPolicy
        )
        bridge?.tab = self
        navigationPolicy.onOpenExternalURL = { [weak self] url in
            self?.externalURL = url
        }
        navigationPolicy.onExplicitUserWebNavigation = { [weak self] in
            self?.prepareForExplicitUserNavigation()
        }
        navigationPolicy.isNavigationTemporarilyBlocked = { [weak self] in
            self?.adblockInstallationPending ?? true
        }
        setAdblockEnabled(adblockEnabled)
    }

    func setAdblockEnabled(_ enabled: Bool) {
        adblockUpdateGeneration &+= 1
        let generation = adblockUpdateGeneration
        if let installedAdblockRuleList {
            userContentController.remove(installedAdblockRuleList)
            self.installedAdblockRuleList = nil
        }
        guard enabled else {
            adblockInstallationPending = false
            adblockOperational = true
            loadPendingInitialURL()
            return
        }

        adblockInstallationPending = true

        Task { @MainActor [weak self] in
            let ruleList = await AppleAdblockContentBlocker.shared.ruleList()
            guard let self, self.adblockUpdateGeneration == generation else { return }
            if let ruleList {
                self.userContentController.add(ruleList)
                self.installedAdblockRuleList = ruleList
                self.adblockOperational = true
            } else {
                self.adblockOperational = false
            }
            self.adblockInstallationPending = false
            self.loadPendingInitialURL()
        }
    }

    private func loadPendingInitialURL() {
        guard let pendingInitialURL else { return }
        self.pendingInitialURL = nil
        page.load(pendingInitialURL)
    }

    func handleCredentialMessage(_ body: [String: Any], frameURL: URL?) {
        guard !isPrivate,
              let credentialBridge,
              let frameURL,
              frameURL.scheme?.lowercased() == "https",
              frameURL.host != nil,
              frameURL.user == nil,
              frameURL.password == nil,
              Set(body.keys) == ["tabId", "navigationNonce", "messageType", "origin"],
              let tabID = body["tabId"] as? String,
              credentialBridge.owns(tabID: tabID),
              let nonce = body["navigationNonce"] as? String,
              !nonce.isEmpty,
              nonce.utf8.count <= 128,
              let messageType = body["messageType"] as? String,
              messageType.utf8.count <= 64,
              let originValue = body["origin"] as? String,
              let origin = URL(string: originValue) else { return }
        let context = XanhCredentialContext(
            documentURL: frameURL,
            topFrameOrigin: origin,
            frameOrigin: origin,
            isPrivate: isPrivate,
            userSelected: true
        )
        guard context.isAllowed else { return }

        if messageType == "credential-ready" {
            credentialNavigation = (nonce, frameURL)
            return
        }
        guard messageType == "credential-request",
              !credentialRequestRunning,
              credentialNavigation?.nonce == nonce,
              credentialNavigation?.documentURL == frameURL,
              page.url == frameURL,
              let credentialRequestHandler else { return }

        credentialRequestRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.credentialRequestRunning = false }
            guard let selected = await credentialRequestHandler(context),
                  self.credentialNavigation?.nonce == nonce,
                  self.credentialNavigation?.documentURL == frameURL,
                  self.page.url == frameURL else { return }
            do {
                _ = try await self.page.callJavaScript(
                    """
                    return globalThis.__xanhBrowserFillCredential?.(
                      username,
                      password,
                      navigationNonce,
                      expectedOrigin
                    ) ?? false;
                    """,
                    arguments: [
                        "username": selected.username,
                        "password": selected.password,
                        "navigationNonce": nonce,
                        "expectedOrigin": originValue,
                    ],
                    contentWorld: BrowserCredentialBridge.contentWorld
                )
            } catch {
                self.errorMessage = "The saved login could not be filled safely."
            }
        }
    }

    func submitAddress(openExternal: (URL) -> Void) {
        switch AddressResolver.resolve(address) {
        case let .web(url):
            let isWaitingForAdblock = adblockInstallationPending
            prepareForExplicitUserNavigation()
            address = url.absoluteString
            if isWaitingForAdblock {
                // The user may type before the default-on rule list finishes compiling.
                // Replace the queued home/session URL instead of outrunning installation.
                pendingInitialURL = url
            } else {
                page.load(url)
            }
        case let .external(url):
            errorMessage = nil
            openExternal(url)
        case nil:
            errorMessage = "Enter a valid address or search."
        }
    }

    func goBack() {
        guard !adblockInstallationPending else { return }
        guard let item = page.backForwardList.backList.last else { return }
        prepareForExplicitUserNavigation()
        page.load(item)
    }

    func goForward() {
        guard !adblockInstallationPending else { return }
        guard let item = page.backForwardList.forwardList.first else { return }
        prepareForExplicitUserNavigation()
        page.load(item)
    }

    func reload() {
        guard !adblockInstallationPending else { return }
        prepareForExplicitUserNavigation()
        page.reload()
    }

    func handleNavigationError(_ error: Error, isForeground: Bool) {
        guard let navigationError = error as? WebPage.NavigationError else {
            processRecovery.markRecoveryFailed()
            errorMessage = error.localizedDescription
            return
        }

        switch navigationError {
        case .webContentProcessTerminated:
            credentialNavigation = nil
            guard processRecovery.recordTermination(currentURL: page.url, address: address) else {
                errorMessage = "Web content stopped again. Reload or enter another address to continue."
                return
            }
            recoverPendingWebContentProcessIfPossible(isForeground: isForeground)
        case .failedProvisionalNavigation(let underlyingError):
            processRecovery.markRecoveryFailed()
            errorMessage = underlyingError.localizedDescription
        case .invalidURL:
            processRecovery.markRecoveryFailed()
            errorMessage = "The page address is invalid."
        case .pageClosed:
            processRecovery.markRecoveryFailed()
            errorMessage = "The web page was closed."
        @unknown default:
            processRecovery.markRecoveryFailed()
            errorMessage = "Navigation stopped unexpectedly."
        }
    }

    func handleNavigationEvent(_ event: WebPage.NavigationEvent) {
        if event == .committed || event == .finished {
            processRecovery.markRecoveryCommitted()
        }
    }

    @discardableResult
    func recoverPendingWebContentProcessIfPossible(isForeground: Bool) -> Bool {
        guard !adblockInstallationPending else { return false }
        guard let request = processRecovery.takeRecoveryRequest(isForeground: isForeground) else {
            return false
        }

        credentialNavigation = nil
        errorMessage = nil
        navigationObservationGeneration &+= 1
        page.load(request)
        return true
    }

    func cancelInFlightWebContentRecoveryForBackground() {
        guard processRecovery.cancelInFlightRecoveryForBackground() else { return }
        navigationObservationGeneration &+= 1
        page.stopLoading()
        errorMessage = "Automatic recovery stopped when Xanh Browser left the foreground. Reload to continue."
    }

    private func prepareForExplicitUserNavigation() {
        pendingInitialURL = nil
        processRecovery.resetForExplicitUserNavigation()
        credentialNavigation = nil
        errorMessage = nil
        navigationObservationGeneration &+= 1
    }
}

@available(iOS 26.0, macOS 26.0, *)
@MainActor
@Observable
final class BrowserWorkspace {
    private static let sessionKey = "XanhBrowserSessionV1"

    @ObservationIgnored
    private let defaults: UserDefaults

    var tabs: [BrowserTab]
    var selectedTabID: BrowserTab.ID
    var adblockEnabled: Bool {
        didSet {
            guard adblockEnabled != oldValue else { return }
            defaults.set(adblockEnabled, forKey: AdblockHostPolicy.preferenceKey)
            tabs.forEach { $0.setAdblockEnabled(adblockEnabled) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialAdblockEnabled = AdblockHostPolicy.isEnabled(
            storedValue: defaults.object(forKey: AdblockHostPolicy.preferenceKey)
        )
        self.adblockEnabled = initialAdblockEnabled
        let session = BrowserSession.decode(defaults.data(forKey: Self.sessionKey))
            ?? BrowserSession(urls: [AddressResolver.defaultHomePage], selectedIndex: 0)
        let restoredTabs = session.urls.map {
            BrowserTab(initialURL: $0, adblockEnabled: initialAdblockEnabled)
        }
        self.tabs = restoredTabs
        self.selectedTabID = restoredTabs[session.selectedIndex].id
    }

    var selectedTab: BrowserTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    @discardableResult
    func addTab(isPrivate: Bool = false, initialURL: URL? = nil) -> Bool {
        guard initialURL.map(AddressResolver.isAllowedWebURL) ?? true else { return false }
        let tab = BrowserTab(
            isPrivate: isPrivate,
            initialURL: initialURL ?? AddressResolver.defaultHomePage,
            adblockEnabled: adblockEnabled
        )
        tabs.append(tab)
        selectedTabID = tab.id
        persistSession()
        return true
    }

    func closeSelectedTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        tabs.remove(at: index)
        selectedTabID = tabs[min(index, tabs.count - 1)].id
        persistSession()
    }

    func persistSession() {
        let regularTabs = tabs.filter { !$0.isPrivate }
        let urls = regularTabs.compactMap { tab -> URL? in
            if let currentURL = tab.page.url, AddressResolver.isAllowedWebURL(currentURL) {
                return currentURL
            }
            guard case let .web(url)? = AddressResolver.resolve(tab.address) else { return nil }
            return url
        }
        let selectedIndex = regularTabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        let session = BrowserSession(urls: urls, selectedIndex: selectedIndex)
        defaults.set(session.encoded(), forKey: Self.sessionKey)
    }
}
