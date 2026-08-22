import Foundation
import WebKit

@available(iOS 26.0, macOS 26.0, *)
@MainActor
private final class WeakCredentialMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: BrowserCredentialBridge?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        bridge?.receive(message)
    }
}

@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class BrowserCredentialBridge: NSObject {
    static let contentWorld = WKContentWorld.world(
        name: "io.github.lamppkk.xanhbrowser.credentials"
    )

    let userContentController = WKUserContentController()
    weak var tab: BrowserTab?

    private static let handlerName = "xanhCredentialBridge"
    private let tabID = UUID().uuidString.lowercased()
    private let messageHandler = WeakCredentialMessageHandler()

    override init() {
        super.init()
        messageHandler.bridge = self
        userContentController.add(
            messageHandler,
            contentWorld: Self.contentWorld,
            name: Self.handlerName
        )
        userContentController.addUserScript(WKUserScript(
            source: bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.contentWorld
        ))
    }

    func receive(_ message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              message.world === Self.contentWorld,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              data.count <= 4_096 else { return }
        tab?.handleCredentialMessage(body, frameURL: message.frameInfo.request.url)
    }

    private var bootstrapScript: String {
        """
        (() => {
          if (window.top !== window || location.protocol !== 'https:') return;
          const handler = window.webkit?.messageHandlers?.xanhCredentialBridge;
          if (!handler) return;
          const tabId = '\(tabID)';
          const navigationNonce = crypto.randomUUID();
          let requestedFor = null;
          let userGestureDeadline = 0;
          const post = messageType => handler.postMessage({
            tabId,
            navigationNonce,
            messageType,
            origin: location.origin
          });
          const requestCredential = target => {
            if (!(target instanceof HTMLInputElement) || target.type !== 'password') return;
            if (performance.now() > userGestureDeadline) return;
            userGestureDeadline = 0;
            requestedFor = target;
            post('credential-request');
          };
          globalThis.__xanhBrowserFillCredential = (
            username,
            passwordValue,
            expectedNonce,
            expectedOrigin
          ) => {
            if (navigationNonce !== expectedNonce || location.origin !== expectedOrigin) return false;
            const password = requestedFor;
            if (!(password instanceof HTMLInputElement) || !password.isConnected) return false;
            const root = password.form || document;
            const user = root.querySelector(
              'input[autocomplete="username"], input[type="email"], input[type="text"]'
            );
            if (user) {
              user.value = username || '';
              user.dispatchEvent(new Event('input', { bubbles: true }));
            }
            password.value = passwordValue || '';
            password.dispatchEvent(new Event('input', { bubbles: true }));
            requestedFor = null;
            return true;
          };
          post('credential-ready');
          document.addEventListener('pointerdown', event => {
            if (!event.isTrusted) return;
            userGestureDeadline = performance.now() + 1500;
            requestCredential(event.target);
          }, true);
          document.addEventListener('keydown', event => {
            if (!event.isTrusted) return;
            userGestureDeadline = performance.now() + 1500;
            requestCredential(event.target);
          }, true);
          document.addEventListener('focusin', event => {
            if (event.isTrusted) requestCredential(event.target);
          }, true);
        })();
        """
    }

    func owns(tabID value: String) -> Bool { value == tabID }
}
