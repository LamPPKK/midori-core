import Foundation
import Observation
import WebKit

@available(iOS 26.0, macOS 26.0, *)
struct BrowserNavigationPolicy: WebPage.NavigationDeciding {
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
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

    init(isPrivate: Bool = false, initialURL: URL = AddressResolver.defaultHomePage) {
        self.isPrivate = isPrivate
        self.address = initialURL.absoluteString

        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.deviceSensorAuthorization = .init(decision: .prompt)
        configuration.applicationNameForUserAgent = "XanhBrowser/1.0"
        configuration.upgradeKnownHostsToHTTPS = true
        self.page = WebPage(
            configuration: configuration,
            navigationDecider: BrowserNavigationPolicy()
        )
        page.load(initialURL)
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
    var tabs: [BrowserTab]
    var selectedTabID: BrowserTab.ID

    init() {
        let initial = BrowserTab()
        self.tabs = [initial]
        self.selectedTabID = initial.id
    }

    var selectedTab: BrowserTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    func addTab(isPrivate: Bool = false) {
        let tab = BrowserTab(isPrivate: isPrivate)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func closeSelectedTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        tabs.remove(at: index)
        selectedTabID = tabs[min(index, tabs.count - 1)].id
    }
}
