package io.github.lamppkk.xanhbrowser.lite

import android.net.Uri
import android.webkit.GeolocationPermissions
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView

internal class XanhWebChromeClient(
    private val activity: BrowserActivity,
) : WebChromeClient() {
    override fun onProgressChanged(view: WebView?, newProgress: Int) {
        activity.onProgress(newProgress)
    }

    override fun onReceivedTitle(view: WebView?, title: String?) {
        activity.onPageChanged(view?.url, title)
    }

    override fun onShowFileChooser(
        webView: WebView?,
        filePathCallback: ValueCallback<Array<Uri>>,
        fileChooserParams: FileChooserParams,
    ): Boolean = activity.chooseFiles(filePathCallback, fileChooserParams.acceptTypes)

    override fun onGeolocationPermissionsShowPrompt(
        origin: String,
        callback: GeolocationPermissions.Callback,
    ) {
        activity.requestGeolocation(origin, callback)
    }

    override fun onGeolocationPermissionsHidePrompt() = activity.cancelGeolocation()
}
