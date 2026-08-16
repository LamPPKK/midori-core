import SwiftUI
import WebKit

@available(iOS 26.0, macOS 26.0, *)
@MainActor
struct BrowserView: View {
    @State private var workspace = BrowserWorkspace()
    @Environment(\.openURL) private var openURL

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
            if let newURL, AddressResolver.isAllowedWebURL(newURL) {
                tab.address = newURL.absoluteString
                workspace.persistSession()
            }
        }
        .onChange(of: workspace.selectedTabID) { _, _ in workspace.persistSession() }
        .onChange(of: tab.externalURL) { _, externalURL in
            guard let externalURL else { return }
            openURL(externalURL)
            tab.externalURL = nil
        }
        .task(id: tab.id) {
            do {
                for try await _ in tab.page.navigations {}
            } catch {
                tab.errorMessage = error.localizedDescription
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
                .disabled(tab.page.backForwardList.backList.isEmpty)
            Button("Forward", systemImage: "chevron.right") { tab.goForward() }
                .labelStyle(.iconOnly)
                .disabled(tab.page.backForwardList.forwardList.isEmpty)
            Button("Reload", systemImage: "arrow.clockwise") { tab.page.reload() }
                .labelStyle(.iconOnly)

            TextField("Search or enter website", text: $tab.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { tab.submitAddress { openURL($0) } }

            Menu {
                Picker("Tabs", selection: $workspace.selectedTabID) {
                    ForEach(workspace.tabs) { candidate in
                        Text(candidate.page.title.isEmpty ? candidate.address : candidate.page.title)
                            .tag(candidate.id)
                    }
                }
                Divider()
                Button("New Tab", systemImage: "plus") { workspace.addTab() }
                Button("New Private Tab", systemImage: "hand.raised") { workspace.addTab(isPrivate: true) }
                Button("Close Tab", systemImage: "xmark") { workspace.closeSelectedTab() }
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
        }
        .padding(10)
        .background(.bar)
    }
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
