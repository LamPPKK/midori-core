package io.github.lamppkk.xanhbrowser.lite.sync

import android.os.Looper
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import io.github.lamppkk.xanhbrowser.sync.BridgeEnvelope
import io.github.lamppkk.xanhbrowser.sync.BridgePolicy
import io.github.lamppkk.xanhbrowser.sync.CredentialContext
import io.github.lamppkk.xanhbrowser.sync.CredentialPolicy
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.net.URI
import java.security.SecureRandom
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Reflection entry point for the reviewed WPEView source fork.
 *
 * The shared on-demand module is also packaged by the System WebView edition,
 * so it must not link WPEView classes directly. The WPE base verifies its
 * source-fork build flag before loading this class. Missing or drifted fork APIs
 * therefore fail closed instead of falling back to page-world JavaScript.
 */
class WpeCredentialBridge private constructor(
    private val activity: AppCompatActivity,
    private val webView: Any,
) {
    private val installMethod = requiredMethod(INSTALL_METHOD, 4)
    private val removeMethod = requiredMethod(REMOVE_METHOD, 0)
    private val callMethod = requiredMethod(CALL_METHOD, 4)
    private val urlMethod = requiredMethod(URL_METHOD, 0)
    private val callbackType = installMethod.parameterTypes[3]
    private val resultCallbackType = callMethod.parameterTypes[3]
    private val callbackProxy = Proxy.newProxyInstance(
        callbackType.classLoader,
        arrayOf(callbackType),
    ) { proxy, method, arguments ->
        when (method.name) {
            "onMessage" -> {
                (arguments?.getOrNull(0) as? String)?.let(::onMessage)
                null
            }
            "equals" -> proxy === arguments?.getOrNull(0)
            "hashCode" -> System.identityHashCode(proxy)
            "toString" -> "XanhWpeCredentialMessageCallback"
            else -> null
        }
    }

    private var expectedUrl: String? = null
    private var navigationChallenge: String? = null
    private var documentNonce: String? = null
    private var requestInFlight = false
    private var dialog: AlertDialog? = null
    private var installed = false
    private var destroyed = false
    private var foreground = false
    private var navigationGeneration = 0L

    init {
        require(callbackType.isInterface) { "WPE isolated message callback must be an interface" }
        require(resultCallbackType.isInterface) { "WPE isolated result callback must be an interface" }
        installed = installMethod.invoke(
            webView,
            WpeCredentialBridgePolicy.bootstrapScript(),
            WORLD_NAME,
            HANDLER_NAME,
            callbackProxy,
        ) == true
        check(installed) { "WPE isolated credential bridge could not be installed" }
    }

    fun navigationStarted(url: String?) {
        resetNavigation(WpeCredentialBridgePolicy.canonicalHttpsUrl(url))
    }

    fun navigationCommitted(url: String?) {
        bindDocument(WpeCredentialBridgePolicy.canonicalHttpsUrl(url))
    }

    fun foregrounded() {
        if (destroyed) return
        foreground = true
        bootstrapAndBind(WpeCredentialBridgePolicy.canonicalHttpsUrl(readCurrentUrl()))
    }

    fun backgrounded() {
        if (destroyed) return
        foreground = false
        navigationGeneration++
        clearPendingRequest()
        navigationChallenge = null
        documentNonce = null
    }

    fun destroy() {
        if (destroyed) return
        destroyed = true
        navigationGeneration++
        clearPendingRequest()
        expectedUrl = null
        navigationChallenge = null
        documentNonce = null
        if (installed) runCatching { removeMethod.invoke(webView) }
        installed = false
    }

    private fun resetNavigation(url: String?) {
        if (destroyed) return
        navigationGeneration++
        clearPendingRequest()
        expectedUrl = url
        navigationChallenge = null
        documentNonce = null
    }

    private fun bindDocument(url: String?) {
        resetNavigation(url)
        val targetUrl = expectedUrl ?: return
        val generation = navigationGeneration
        val challenge = randomToken()
        navigationChallenge = challenge
        runCatching {
            callMethod.invoke(
                webView,
                BIND_FUNCTION,
                mapOf(
                    "navigationGeneration" to generation.toString(),
                    "navigationChallenge" to challenge,
                ),
                WORLD_NAME,
                null,
            )
        }.onFailure {
            if (navigationGeneration == generation && expectedUrl == targetUrl) {
                navigationChallenge = null
            }
        }
    }

    private fun bootstrapAndBind(url: String?) {
        resetNavigation(url)
        val targetUrl = expectedUrl ?: return
        val generation = navigationGeneration
        val callback = resultCallback { result ->
            if (result != "true") return@resultCallback
            activity.runOnUiThread {
                if (isForeground() && navigationGeneration == generation &&
                    expectedUrl == targetUrl &&
                    WpeCredentialBridgePolicy.canonicalHttpsUrl(readCurrentUrl()) == targetUrl
                ) {
                    bindDocument(targetUrl)
                }
            }
        }
        runCatching {
            callMethod.invoke(
                webView,
                WpeCredentialBridgePolicy.bootstrapFunctionBody(),
                emptyMap<String, String>(),
                WORLD_NAME,
                callback,
            )
        }
    }

    private fun clearPendingRequest() {
        requestInFlight = false
        dialog?.setOnDismissListener(null)
        dialog?.dismiss()
        dialog = null
    }

    private fun onMessage(data: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            activity.runOnUiThread { onMessage(data) }
            return
        }
        if (!isForeground() || destroyed || !installed || requestInFlight) return
        val request = WpeCredentialBridgePolicy.parseRequest(data) ?: return
        val expected = expectedUrl ?: return
        val challenge = navigationChallenge ?: return
        val liveUrl = WpeCredentialBridgePolicy.canonicalHttpsUrl(readCurrentUrl()) ?: return
        if (liveUrl != expected) return
        if (request.messageType == READY_MESSAGE_TYPE) {
            if (WpeCredentialBridgePolicy.validateReady(
                    request,
                    TAB_ID,
                    navigationGeneration,
                    challenge,
                    liveUrl,
                )
            ) {
                documentNonce = request.navigationNonce
            }
            return
        }
        val nonce = documentNonce ?: return
        if (!WpeCredentialBridgePolicy.validateRequest(
                request,
                TAB_ID,
                navigationGeneration,
                challenge,
                nonce,
                liveUrl,
                MESSAGE_TYPE,
            )
        ) return
        requestInFlight = true
        val navigationUrl = liveUrl
        val navigationNonce = nonce
        val generation = navigationGeneration

        activity.lifecycleScope.launch {
            val runtime = LiteSyncCoordinator.get(activity).runtimeOrNull()
            if (runtime == null || !runCatching { runtime.touchVault() }.getOrDefault(false)) {
                finishRequest(generation)
                return@launch
            }
            val origin = CredentialPolicy.canonicalHttpsOrigin(
                request.sourceOrigin,
                requireOriginOnly = true,
            )
            if (origin == null) {
                finishRequest(generation)
                return@launch
            }
            val context = CredentialContext(
                documentUrl = navigationUrl,
                topFrameOrigin = origin,
                frameOrigin = origin,
                isPrivate = false,
                userSelected = true,
            )
            val logins = withContext(Dispatchers.IO) {
                runCatching { runtime.credentialLogins(context) }
            }.getOrElse {
                finishRequest(generation)
                return@launch
            }
            if (logins.isEmpty() || activity.isFinishing || activity.isDestroyed || !isForeground() ||
                !isCurrentNavigation(generation, challenge, navigationUrl, navigationNonce)
            ) {
                finishRequest(generation)
                return@launch
            }
            val shown = AlertDialog.Builder(activity)
                .setTitle(R.string.sync_passwords)
                .setItems(
                    logins.map {
                        it.username.ifBlank { activity.getString(R.string.sync_empty_username) }
                    }.toTypedArray(),
                ) { _, index ->
                    val selected = logins.getOrNull(index) ?: return@setItems
                    val allowed = isForeground() &&
                        isCurrentNavigation(generation, challenge, navigationUrl, navigationNonce) &&
                        runCatching { runtime.touchVault() }.getOrDefault(false) &&
                        CredentialPolicy.isAllowed(context, vaultUnlocked = true)
                    if (!allowed) return@setItems
                    val selectedId = selected.id
                    sendCredential(
                        request,
                        generation,
                        challenge,
                        origin,
                        selected.username,
                        selected.password,
                    ) { filled ->
                        if (filled) activity.lifecycleScope.launch(Dispatchers.IO) {
                            runCatching { runtime.touchLogin(selectedId) }
                        }
                    }
                }
                .setNegativeButton(android.R.string.cancel, null)
                .create()
            shown.setOnDismissListener {
                if (dialog === shown) dialog = null
                finishRequest(generation)
            }
            dialog = shown
            shown.show()
        }
    }

    private fun isForeground(): Boolean = foreground &&
        activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)

    private fun isCurrentNavigation(
        generation: Long,
        challenge: String,
        url: String,
        nonce: String,
    ): Boolean = !destroyed && navigationGeneration == generation &&
        navigationChallenge == challenge && documentNonce == nonce && expectedUrl == url &&
        WpeCredentialBridgePolicy.canonicalHttpsUrl(readCurrentUrl()) == url

    private fun finishRequest(generation: Long) {
        if (navigationGeneration == generation) requestInFlight = false
    }

    private fun sendCredential(
        request: WpeCredentialRequest,
        generation: Long,
        challenge: String,
        origin: String,
        username: String,
        password: String,
        completed: (Boolean) -> Unit,
    ): Boolean {
        if (username.toByteArray(Charsets.UTF_8).size > MAX_USERNAME_BYTES ||
            password.isEmpty() || password.toByteArray(Charsets.UTF_8).size > MAX_PASSWORD_BYTES
        ) return false
        val callback = resultCallback { result ->
            completed(result == "true")
        }
        return runCatching {
            callMethod.invoke(
                webView,
                RESPONSE_FUNCTION,
                mapOf(
                    "expectedGeneration" to generation.toString(),
                    "expectedChallenge" to challenge,
                    "expectedNonce" to request.navigationNonce,
                    "expectedRequestId" to request.requestId,
                    "expectedOrigin" to origin,
                    "username" to username,
                    "password" to password,
                ),
                WORLD_NAME,
                callback,
            )
        }.isSuccess
    }

    private fun resultCallback(completed: (String?) -> Unit): Any = Proxy.newProxyInstance(
        resultCallbackType.classLoader,
        arrayOf(resultCallbackType),
    ) { proxy, method, arguments ->
        when (method.name) {
            "onResult" -> {
                completed(arguments?.getOrNull(0) as? String)
                null
            }
            "equals" -> proxy === arguments?.getOrNull(0)
            "hashCode" -> System.identityHashCode(proxy)
            "toString" -> "XanhWpeCredentialResultCallback"
            else -> null
        }
    }

    private fun readCurrentUrl(): String? = runCatching {
        urlMethod.invoke(webView) as? String
    }.getOrNull()

    private fun requiredMethod(name: String, parameterCount: Int): Method =
        webView.javaClass.methods.singleOrNull {
            it.name == name && it.parameterCount == parameterCount
        } ?: error("Required WPE source-fork method is missing: $name")

    companion object {
        private const val INSTALL_METHOD = "installIsolatedBridge"
        private const val REMOVE_METHOD = "removeIsolatedBridge"
        private const val CALL_METHOD = "callIsolatedJavascriptFunction"
        private const val URL_METHOD = "getUrl"
        private const val WORLD_NAME = "xanhBrowserCredentials"
        private const val HANDLER_NAME = "xanhWpeCredentials"
        private const val MESSAGE_TYPE = "credential-request"
        private const val READY_MESSAGE_TYPE = "bridge-ready"
        private const val BIND_FUNCTION =
            "return globalThis.__xanhBindDocument(navigationGeneration, navigationChallenge);"
        private const val RESPONSE_FUNCTION =
            "return globalThis.__xanhAcceptCredential(expectedGeneration, expectedChallenge, " +
                "expectedNonce, expectedRequestId, expectedOrigin, username, password);"
        private const val TAB_ID = 1L
        private const val MAX_USERNAME_BYTES = 1_024
        private const val MAX_PASSWORD_BYTES = 4_096
        private val secureRandom = SecureRandom()

        private fun randomToken(): String = ByteArray(16).also(secureRandom::nextBytes)
            .joinToString("") { "%02x".format(it) }

        @JvmStatic
        fun attach(activity: AppCompatActivity, webView: Any): WpeCredentialBridge =
            WpeCredentialBridge(activity, webView)
    }
}

internal data class WpeCredentialRequest(
    val tabId: Long,
    val navigationGeneration: Long,
    val navigationChallenge: String,
    val navigationNonce: String,
    val requestId: String,
    val sourceOrigin: String,
    val messageType: String,
)

internal object WpeCredentialBridgePolicy {
    private const val MAX_MESSAGE_CHARS = 4_096
    private val noncePattern = Regex("^[0-9a-f]{32}$")
    private val requestKeys = setOf(
        "tabId",
        "navigationGeneration",
        "navigationChallenge",
        "navigationNonce",
        "requestId",
        "sourceOrigin",
        "messageType",
    )

    fun parseRequest(data: String): WpeCredentialRequest? {
        if (data.length !in 1..MAX_MESSAGE_CHARS) return null
        val parsed = runCatching { JSONObject(data) }.getOrNull() ?: return null
        val keys = buildSet {
            val iterator = parsed.keys()
            while (iterator.hasNext()) add(iterator.next())
        }
        if (keys != requestKeys) return null
        val tabNumber = parsed.opt("tabId") as? Number ?: return null
        val tabId = tabNumber.toLong()
        if (tabNumber.toDouble() != tabId.toDouble()) return null
        val generationNumber = parsed.opt("navigationGeneration") as? Number ?: return null
        val generation = generationNumber.toLong()
        if (generation < 0 || generationNumber.toDouble() != generation.toDouble()) return null
        val challenge = parsed.opt("navigationChallenge") as? String ?: return null
        val nonce = parsed.opt("navigationNonce") as? String ?: return null
        val requestId = parsed.opt("requestId") as? String ?: return null
        val sourceOrigin = parsed.opt("sourceOrigin") as? String ?: return null
        val messageType = parsed.opt("messageType") as? String ?: return null
        if (!noncePattern.matches(challenge) || !noncePattern.matches(nonce) ||
            !noncePattern.matches(requestId)
        ) return null
        return WpeCredentialRequest(
            tabId,
            generation,
            challenge,
            nonce,
            requestId,
            sourceOrigin,
            messageType,
        )
    }

    fun canonicalHttpsUrl(value: String?): String? {
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

    fun validateRequest(
        request: WpeCredentialRequest,
        expectedTabId: Long,
        expectedGeneration: Long,
        expectedChallenge: String,
        expectedNonce: String,
        currentUrl: String,
        messageType: String,
    ): Boolean = request.navigationGeneration == expectedGeneration &&
        request.navigationChallenge == expectedChallenge && BridgePolicy.validate(
        BridgeEnvelope(
            request.tabId,
            request.navigationNonce,
            request.sourceOrigin,
            request.messageType,
        ),
        expectedTabId,
        expectedNonce,
        currentUrl,
        setOf(messageType),
    )

    fun validateReady(
        request: WpeCredentialRequest,
        expectedTabId: Long,
        expectedGeneration: Long,
        expectedChallenge: String,
        currentUrl: String,
    ): Boolean = request.requestId == request.navigationNonce && validateRequest(
        request,
        expectedTabId,
        expectedGeneration,
        expectedChallenge,
        request.navigationNonce,
        currentUrl,
        "bridge-ready",
    )

    fun bootstrapScript(): String = """
        (() => {
          if (window.top !== window || !globalThis.crypto) return false;
          if (globalThis.__xanhCredentialBridgeInstalled === true) return true;
          const handler = window.webkit && window.webkit.messageHandlers &&
            window.webkit.messageHandlers.xanhWpeCredentials;
          if (!handler) return false;
          globalThis.__xanhCredentialBridgeInstalled = true;
          const nonceBytes = new Uint8Array(16);
          globalThis.crypto.getRandomValues(nonceBytes);
          const navigationNonce = Array.from(nonceBytes, value =>
            value.toString(16).padStart(2, '0')).join('');
          let boundGeneration = -1;
          let navigationChallenge = null;
          let requestedFor = null;
          let requestedForId = null;
          let userGestureDeadline = 0;
          const randomToken = () => {
            const bytes = new Uint8Array(16);
            globalThis.crypto.getRandomValues(bytes);
            return Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('');
          };
          const send = (messageType, requestId) => handler.postMessage(JSON.stringify({
            tabId: 1,
            navigationGeneration: boundGeneration,
            navigationChallenge,
            navigationNonce,
            requestId,
            sourceOrigin: location.origin,
            messageType
          }));
          globalThis.__xanhBindDocument = (candidateGeneration, candidateChallenge) => {
            const generation = Number(candidateGeneration);
            if (!Number.isSafeInteger(generation) || generation < boundGeneration ||
                !/^[0-9a-f]{32}$/.test(candidateChallenge)) return false;
            if (generation === boundGeneration && navigationChallenge !== candidateChallenge)
              return false;
            boundGeneration = generation;
            navigationChallenge = candidateChallenge;
            requestedFor = null;
            requestedForId = null;
            send('bridge-ready', navigationNonce);
            return true;
          };
          const noteUserGesture = () => { userGestureDeadline = performance.now() + 1500; };
          const requestCredential = target => {
            if (!(target instanceof HTMLInputElement) || target.type !== 'password') return;
            if (navigationChallenge === null || performance.now() > userGestureDeadline) return;
            userGestureDeadline = 0;
            requestedFor = target;
            requestedForId = randomToken();
            send('credential-request', requestedForId);
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
          globalThis.__xanhAcceptCredential = (
            expectedGeneration,
            expectedChallenge,
            expectedNonce,
            expectedRequestId,
            expectedOrigin,
            username,
            selectedPassword
          ) => {
            if (Number(expectedGeneration) !== boundGeneration ||
                expectedChallenge !== navigationChallenge ||
                expectedNonce !== navigationNonce || expectedRequestId !== requestedForId ||
                expectedOrigin !== location.origin || document.visibilityState !== 'visible')
              return false;
            const password = requestedFor;
            if (!(password instanceof HTMLInputElement) || password.type !== 'password' ||
                !password.isConnected) return false;
            const root = password.form || document;
            const user = root.querySelector(
              'input[autocomplete="username"], input[type="email"], input[type="text"]');
            if (user) {
              user.value = username || '';
              user.dispatchEvent(new Event('input', { bubbles: true }));
            }
            password.value = selectedPassword || '';
            password.dispatchEvent(new Event('input', { bubbles: true }));
            requestedFor = null;
            requestedForId = null;
            return true;
          };
          return true;
        })();
    """.trimIndent()

    fun bootstrapFunctionBody(): String = "return ${bootstrapScript()}"
}
