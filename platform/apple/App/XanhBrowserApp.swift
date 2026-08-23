import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
@main
@MainActor
struct XanhBrowserApp: App {
    @State private var firefoxSyncProcess = XanhFirefoxSyncProcessService()

    var body: some Scene {
        WindowGroup("Xanh Browser") {
            BrowserView(firefoxSyncProcess: firefoxSyncProcess)
        }
    }
}
