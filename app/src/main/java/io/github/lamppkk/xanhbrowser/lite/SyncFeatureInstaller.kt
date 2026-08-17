package io.github.lamppkk.xanhbrowser.lite

import android.content.Intent
import android.webkit.WebView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus

internal class SyncFeatureInstaller(private val activity: AppCompatActivity) {
    private val manager = SplitInstallManagerFactory.create(activity)
    private var credentialBridge: Any? = null

    fun open(currentUrl: String?, currentTitle: String?) {
        if (!BuildConfig.XANH_SYNC_FEATURE_ENABLED) return
        if (MODULE in manager.installedModules) {
            launch(currentUrl, currentTitle)
            return
        }
        lateinit var listener: SplitInstallStateUpdatedListener
        listener = SplitInstallStateUpdatedListener { state ->
            if (state.moduleNames().contains(MODULE)) {
                when (state.status()) {
                    SplitInstallSessionStatus.INSTALLED -> {
                        manager.unregisterListener(listener)
                        launch(currentUrl, currentTitle)
                    }
                    SplitInstallSessionStatus.FAILED,
                    SplitInstallSessionStatus.CANCELED -> {
                        manager.unregisterListener(listener)
                        unavailable()
                    }
                    SplitInstallSessionStatus.CANCELING,
                    SplitInstallSessionStatus.DOWNLOADED,
                    SplitInstallSessionStatus.DOWNLOADING,
                    SplitInstallSessionStatus.INSTALLING,
                    SplitInstallSessionStatus.PENDING,
                    SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION,
                    SplitInstallSessionStatus.UNKNOWN -> Unit
                }
            }
        }
        manager.registerListener(listener)
        manager.startInstall(SplitInstallRequest.newBuilder().addModule(MODULE).build())
            .addOnFailureListener {
                manager.unregisterListener(listener)
                unavailable()
            }
    }

    fun attachCredentialBridge(webView: WebView) {
        if (!BuildConfig.XANH_SYNC_FEATURE_ENABLED || MODULE !in manager.installedModules || credentialBridge != null) return
        runCatching {
            SplitCompat.installActivity(activity)
            val type = Class.forName(BRIDGE_CLASS, true, activity.classLoader)
            credentialBridge = type.getMethod("attach", AppCompatActivity::class.java, WebView::class.java)
                .invoke(null, activity, webView)
            navigationStarted(webView.url)
            navigationCommitted(webView.url, webView.title)
        }.onFailure { unavailable() }
    }

    fun navigationStarted(url: String?) = invokeBridge("navigationStarted", url)

    fun navigationCommitted(url: String?, title: String?) {
        invokeBridge("navigationCommitted", url)
        recordHistory(url, title)
    }

    fun destroy() {
        runCatching { credentialBridge?.javaClass?.getMethod("destroy")?.invoke(credentialBridge) }
        credentialBridge = null
    }

    private fun invokeBridge(name: String, value: String?) {
        runCatching {
            credentialBridge?.javaClass?.getMethod(name, String::class.java)?.invoke(credentialBridge, value)
        }
    }

    private fun recordHistory(url: String?, title: String?) {
        if (MODULE !in manager.installedModules) return
        runCatching {
            SplitCompat.installActivity(activity)
            Class.forName(HISTORY_CLASS, true, activity.classLoader)
                .getMethod("record", android.content.Context::class.java, String::class.java, String::class.java)
                .invoke(null, activity.applicationContext, url, title)
        }
    }

    private fun launch(currentUrl: String?, currentTitle: String?) {
        runCatching {
            SplitCompat.installActivity(activity)
            activity.startActivity(
                Intent().setClassName(activity, ACTIVITY_CLASS)
                    .putExtra("xanh.sync.current_url", currentUrl)
                    .putExtra("xanh.sync.current_title", currentTitle)
                    .putExtra("xanh.sync.redirect_uri", REDIRECT_URI)
                    .putExtra("xanh.sync.device_name", activity.getString(R.string.app_name))
                    .putExtra("xanh.sync.client_id", BuildConfig.XANH_FXA_CLIENT_ID)
                    .putExtra("xanh.sync.mozilla_approved", BuildConfig.XANH_FXA_PRODUCTION_APPROVED)
                    .putExtra("xanh.sync.self_hosted_only", BuildConfig.XANH_SYNC_SELF_HOSTED_ONLY)
                    .putExtra("xanh.sync.wpe", false),
            )
        }.onFailure { unavailable() }
    }

    private fun unavailable() {
        Toast.makeText(activity, R.string.sync_feature_unavailable, Toast.LENGTH_LONG).show()
    }

    companion object {
        private const val MODULE = "sync_feature"
        private const val ACTIVITY_CLASS = "io.github.lamppkk.xanhbrowser.lite.sync.SyncFeatureActivity"
        private const val BRIDGE_CLASS = "io.github.lamppkk.xanhbrowser.lite.sync.LiteCredentialBridge"
        private const val HISTORY_CLASS = "io.github.lamppkk.xanhbrowser.lite.sync.LiteHistoryRecorder"
        private const val REDIRECT_URI = "xanh-browser-lite://accounts/oauth"
    }
}
