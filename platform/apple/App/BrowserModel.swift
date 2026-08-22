import Foundation
import Observation
import WebKit

@available(iOS 26.0, macOS 26.0, *)
final class BrowserNavigationPolicy: WebPage.NavigationDeciding {
    var onOpenExternalURL: ((URL) -> Void)?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        #if os(macOS)
        let hasTrustedButtonActivation = action.buttonNumber >= 0
        #else
        let hasTrustedButtonActivation = !action.buttonNumber.isEmpty
        #endif
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
    var credentialRequestHandler: ((XanhCredentialContext) async -> XanhCredentialRecord?)?

    @ObservationIgnored
    private let credentialBridge: BrowserCredentialBridge?
    @ObservationIgnored
    private var credentialNavigation: (nonce: String, documentURL: URL)?
    @ObservationIgnored
    private var credentialRequestRunning = false

    init(isPrivate: Bool = false, initialURL: URL = AddressResolver.defaultHomePage) {
        self.isPrivate = isPrivate
        self.address = initialURL.absoluteString

        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.deviceSensorAuthorization = .init(decision: .prompt)
        configuration.applicationNameForUserAgent = "XanhBrowser/1.0"
        configuration.upgradeKnownHostsToHTTPS = true
        let bridge = isPrivate ? nil : BrowserCredentialBridge()
        if let bridge { configuration.userContentController = bridge.userContentController }
        self.credentialBridge = bridge
        let navigationPolicy = BrowserNavigationPolicy()
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: navigationPolicy
        )
        bridge?.tab = self
        navigationPolicy.onOpenExternalURL = { [weak self] url in
            self?.externalURL = url
        }
        page.load(initialURL)
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
            errorMessage = nil
            address = url.absoluteString
            page.load(url)
        case let .external(url):
            errorMessage = nil
            openExternal(url)
        case nil:
            errorMessage = "Enter a valid address or search."
        }
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        page.load(item)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        page.load(item)
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let session = BrowserSession.decode(defaults.data(forKey: Self.sessionKey))
            ?? BrowserSession(urls: [AddressResolver.defaultHomePage], selectedIndex: 0)
        let restoredTabs = session.urls.map { BrowserTab(initialURL: $0) }
        self.tabs = restoredTabs
        self.selectedTabID = restoredTabs[session.selectedIndex].id
    }

    var selectedTab: BrowserTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    func addTab(isPrivate: Bool = false) {
        let tab = BrowserTab(isPrivate: isPrivate)
        tabs.append(tab)
        selectedTabID = tab.id
        persistSession()
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
