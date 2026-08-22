package io.github.lamppkk.xanhbrowser.lite.sync

import android.net.Uri
import android.webkit.WebView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.ScriptHandler
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.github.lamppkk.xanhbrowser.sync.BridgeEnvelope
import io.github.lamppkk.xanhbrowser.sync.BridgePolicy
import io.github.lamppkk.xanhbrowser.sync.CredentialContext
import io.github.lamppkk.xanhbrowser.sync.CredentialPolicy
import java.net.URI
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Reflection entry point kept inside the on-demand module.
 *
 * The base Lite APK contains no Application Services or WebKit bridge code.
 * Once Play installs the module, this origin-bound listener is attached to the
 * existing System WebView. WPE deliberately never calls this class.
 */
class LiteCredentialBridge private constructor(
    private val activity: AppCompatActivity,
    private val webView: WebView,
) {
    private val tabId = 1L
    private var committedUrl: String? = null
    private var navigationNonce = UUID.randomUUID().toString()
    private var scriptHandler: ScriptHandler? = null
    private var installed = false

    init {
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(
                webView,
                BRIDGE_NAME,
                // Some serviced legacy WebView releases reject the
                // non-standard `https://*` rule. The callback validates the
                // main frame and exact committed HTTPS origin before use.
                setOf("*"),
                WebViewCompat.WebMessageListener(::onMessage),
            )
            installed = true
        }
    }

    fun navigationStarted(url: String?) {
        committedUrl = canonicalHttpsUrl(url)
        navigationNonce = UUID.randomUUID().toString()
        if (!installed || committedUrl == null ||
            !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        ) return
        scriptHandler?.remove()
        val origin = CredentialPolicy.canonicalHttpsOrigin(committedUrl!!) ?: return
        scriptHandler = WebViewCompat.addDocumentStartJavaScript(
            webView,
            bootstrapScript(navigationNonce),
            setOf(origin),
        )
    }

    fun navigationCommitted(url: String?) {
        committedUrl = canonicalHttpsUrl(url)
    }

    fun destroy() {
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            scriptHandler?.remove()
        }
        scriptHandler = null
        if (installed && WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.removeWebMessageListener(webView, BRIDGE_NAME)
        }
        installed = false
        committedUrl = null
    }

    private fun onMessage(
        view: WebView,
        message: WebMessageCompat,
        sourceOrigin: Uri,
        isMainFrame: Boolean,
        reply: JavaScriptReplyProxy,
    ) {
        if (!isMainFrame || message.type != WebMessageCompat.TYPE_STRING) return
        val currentUrl = committedUrl ?: return
        val data = message.data ?: return
        if (data.length > MAX_BRIDGE_MESSAGE_CHARS) return
        val parsed = runCatching { JSONObject(data) }.getOrNull() ?: return
        val envelope = BridgeEnvelope(
            parsed.optLong("tabId", -1),
            parsed.optString("navigationNonce"),
            sourceOrigin.toString(),
            parsed.optString("messageType"),
        )
        if (!BridgePolicy.validate(
                envelope,
                tabId,
                navigationNonce,
                currentUrl,
                setOf("credential-request"),
            )
        ) return
        val requestUrl = view.url ?: return
        activity.lifecycleScope.launch {
            val runtime = LiteSyncCoordinator.get(activity).runtimeOrNull() ?: return@launch
            if (!runCatching { runtime.touchVault() }.getOrDefault(false)) return@launch
            val requestedOrigin = CredentialPolicy.canonicalHttpsOrigin(
                sourceOrigin.toString(),
                requireOriginOnly = true,
            ) ?: return@launch
            val context = CredentialContext(
                documentUrl = requestUrl,
                topFrameOrigin = requestedOrigin,
                frameOrigin = requestedOrigin,
                isPrivate = false,
                userSelected = true,
            )
            val logins = withContext(Dispatchers.IO) {
                runCatching { runtime.credentialLogins(context) }
            }.getOrElse { return@launch }
            if (logins.isEmpty() || activity.isFinishing) return@launch
            AlertDialog.Builder(activity)
                .setTitle(R.string.sync_passwords)
                .setItems(logins.map { it.username.ifBlank { activity.getString(R.string.sync_empty_username) } }.toTypedArray()) {
                    _, index ->
                    val selected = logins[index]
                    val allowed = runCatching { runtime.touchVault() }.getOrDefault(false) &&
                        CredentialPolicy.isAllowed(context, vaultUnlocked = true)
                    if (!allowed || navigationNonce != envelope.navigationNonce || webView.url != requestUrl) {
                        return@setItems
                    }
                    if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                        reply.postMessage(
                            JSONObject()
                                .put("type", "credential-selected")
                                .put("username", selected.username)
                                .put("password", selected.password)
                                .toString(),
                        )
                    }
                    activity.lifecycleScope.launch(Dispatchers.IO) {
                        runCatching { runtime.touchLogin(selected.id) }
                    }
                }
                .setNegativeButton(android.R.string.cancel, null)
                .show()
        }
    }

    private fun bootstrapScript(nonce: String): String = """
        (() => {
          if (window.top !== window || !window.$BRIDGE_NAME) return;
          let requestedFor = null;
          let userGestureDeadline = 0;
          const noteUserGesture = () => { userGestureDeadline = performance.now() + 1500; };
          const requestCredential = target => {
            if (!(target instanceof HTMLInputElement) || target.type !== 'password') return;
            if (performance.now() > userGestureDeadline) return;
            userGestureDeadline = 0;
            requestedFor = target;
            window.$BRIDGE_NAME.postMessage(JSON.stringify({
              tabId: $tabId,
              navigationNonce: '$nonce',
              messageType: 'credential-request'
            }));
          };
          document.addEventListener('pointerdown', event => {
            if (!event.isTrusted) return;
            noteUserGesture();
            requestCredential(event.target);
          }, true);
          document.addEventListener('keydown', event => {
            if (event.isTrusted) noteUserGesture();
          }, true);
          document.addEventListener('focusin', event => {
            if (!event.isTrusted) return;
            requestCredential(event.target);
          }, true);
          window.$BRIDGE_NAME.onmessage = event => {
            let credential;
            try { credential = JSON.parse(event.data); } catch (_) { return; }
            if (!credential || credential.type !== 'credential-selected') return;
            const password = requestedFor;
            if (!(password instanceof HTMLInputElement) || !password.isConnected) return;
            const root = password.form || document;
            const user = root.querySelector('input[autocomplete="username"], input[type="email"], input[type="text"]');
            if (user) {
              user.value = credential.username || '';
              user.dispatchEvent(new Event('input', { bubbles: true }));
            }
            password.value = credential.password || '';
            password.dispatchEvent(new Event('input', { bubbles: true }));
            requestedFor = null;
          };
        })();
    """.trimIndent()

    private fun canonicalHttpsUrl(value: String?): String? {
        val candidate = value ?: return null
        return runCatching {
            val uri = URI(candidate)
            require(
                uri.scheme.equals("https", true) && uri.host != null && uri.userInfo == null &&
                    uri.port in -1..65_535,
            )
            uri.toASCIIString()
        }.getOrNull()
    }

    companion object {
        private const val BRIDGE_NAME = "xanhLiteCredentials"
        private const val MAX_BRIDGE_MESSAGE_CHARS = 4_096

        @JvmStatic
        fun attach(activity: AppCompatActivity, webView: WebView): LiteCredentialBridge =
            LiteCredentialBridge(activity, webView)
    }
}
