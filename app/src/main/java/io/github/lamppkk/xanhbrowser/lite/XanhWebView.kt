package io.github.lamppkk.xanhbrowser.lite

import android.content.Context
import android.util.AttributeSet
import android.webkit.WebView

/** Xanh-owned widget boundary around the serviced API-26 Android backend. */
open class XanhWebView : WebView {
    constructor(context: Context) : super(context)
    constructor(context: Context, attributes: AttributeSet?) : super(context, attributes)

    val engineInfo: XanhWebViewEngineInfo
        get() = XanhWebViewContract.engineInfo
}

data class XanhWebViewEngineInfo(
    val apiVersion: String,
    val backendId: String,
    val replacementTarget: String,
    val isFallback: Boolean,
)

object XanhWebViewContract {
    const val API_VERSION = "0.1.0-alpha.1"
    const val BACKEND_ID = "android-system-webview"
    const val REPLACEMENT_TARGET = "wpe-android"

    val engineInfo = XanhWebViewEngineInfo(
        apiVersion = API_VERSION,
        backendId = BACKEND_ID,
        replacementTarget = REPLACEMENT_TARGET,
        isFallback = true,
    )
}
