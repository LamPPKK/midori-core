package io.github.lamppkk.xanhbrowser.lite.webkit

import android.content.Context
import android.util.AttributeSet
import org.wpewebkit.wpeview.WPEView

/**
 * Xanh-owned embedding boundary for the Android WPE backend.
 *
 * Application code should depend on this type rather than constructing the
 * upstream WPEView widget directly. The source-built backend adds the guarded
 * navigation and isolated-world capabilities described by [capabilities].
 */
class XanhWebView : WPEView {
    constructor(context: Context) : super(context)
    constructor(context: Context, attributes: AttributeSet?) : super(context, attributes)

    val engineInfo: XanhWebViewEngineInfo
        get() = XanhWebViewContract.engineInfo(BuildConfig.XANH_WPE_SOURCE_FORK)
}

data class XanhWebViewEngineInfo(
    val apiVersion: String,
    val backendId: String,
    val runtimeVersion: String,
    val sourceFork: Boolean,
    val capabilities: Set<String>,
)

object XanhWebViewContract {
    const val API_VERSION = "0.1.0-alpha.1"
    const val BACKEND_ID = "wpe-android"

    private val previewCapabilities = setOf(
        "navigation-events",
        "tls-fail-closed",
    )
    private val sourceForkCapabilities = previewCapabilities + setOf(
        "preload-navigation-policy",
        "named-isolated-script-world",
        "typed-script-messages",
    )

    fun engineInfo(sourceFork: Boolean) = XanhWebViewEngineInfo(
        apiVersion = API_VERSION,
        backendId = BACKEND_ID,
        runtimeVersion = BuildConfig.XANH_WEBVIEW_RUNTIME_VERSION,
        sourceFork = sourceFork,
        capabilities = if (sourceFork) sourceForkCapabilities else previewCapabilities,
    )
}
