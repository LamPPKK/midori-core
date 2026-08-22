package io.github.lamppkk.xanhbrowser.lite

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.os.Build
import android.webkit.RenderProcessGoneDetail
import android.webkit.SafeBrowsingResponse
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.net.http.SslError
import android.widget.Toast
import androidx.annotation.RequiresApi

@SuppressLint("MissingOnRenderProcessGone") // This client handles renderer loss below.
internal class XanhWebViewClient(
    private val activity: BrowserActivity,
) : WebViewClient() {
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        val uri = request.url
        return when (uri.scheme?.lowercase()) {
            "http", "https" -> !AddressResolver.isValidWebUrl(uri.toString())
            "mailto", "tel", "geo", "market" -> {
                if (
                    request.isForMainFrame &&
                    request.hasGesture() &&
                    !request.isRedirect &&
                    AddressResolver.isExternal(uri.toString())
                ) activity.openExternal(uri) else true
            }
            else -> true
        }
    }

    override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
        activity.onPageStarted(url)
    }

    override fun onPageFinished(view: WebView?, url: String?) {
        activity.onPageChanged(url, view?.title)
    }

    override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler, error: SslError?) {
        handler.cancel()
        Toast.makeText(activity, R.string.tls_error, Toast.LENGTH_LONG).show()
    }

    @RequiresApi(Build.VERSION_CODES.O_MR1)
    override fun onSafeBrowsingHit(
        view: WebView,
        request: WebResourceRequest,
        threatType: Int,
        callback: SafeBrowsingResponse,
    ) {
        callback.backToSafety(true)
        Toast.makeText(activity, R.string.unsafe_page_blocked, Toast.LENGTH_LONG).show()
    }

    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        return activity.onRendererGone(view)
    }
}
