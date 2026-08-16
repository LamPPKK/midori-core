import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
@main
struct XanhBrowserApp: App {
    var body: some Scene {
        WindowGroup("Xanh Browser") {
            BrowserView()
        }
    }
}
