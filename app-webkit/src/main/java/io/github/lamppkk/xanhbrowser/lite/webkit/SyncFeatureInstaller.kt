package io.github.lamppkk.xanhbrowser.lite.webkit

import android.content.Intent
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import org.wpewebkit.wpeview.WPEView

internal class SyncFeatureInstaller(private val activity: AppCompatActivity) {
    private val manager = SplitInstallManagerFactory.create(activity)
    private var credentialBridge: Any? = null
    private var bridgeFailed = false

    fun open(currentUrl: String?, currentTitle: String?) {
        if (!BuildConfig.XANH_SYNC_FEATURE_ENABLED) return
        if (MODULE in manager.installedModules) return launch(currentUrl, currentTitle)
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

    fun navigationCommitted(url: String?, title: String?) {
        if (!BuildConfig.XANH_SYNC_FEATURE_ENABLED || MODULE !in manager.installedModules) return
        invokeBridge("navigationCommitted", url)
        runCatching {
            SplitCompat.installActivity(activity)
            Class.forName(HISTORY_CLASS, true, activity.classLoader)
                .getMethod("record", android.content.Context::class.java, String::class.java, String::class.java)
                .invoke(null, activity.applicationContext, url, title)
        }
    }

    fun attachCredentialBridge(webView: WPEView) {
        if (!BuildConfig.XANH_SYNC_FEATURE_ENABLED || !BuildConfig.XANH_WPE_SOURCE_FORK ||
            MODULE !in manager.installedModules || credentialBridge != null || bridgeFailed
        ) return
        runCatching {
            SplitCompat.installActivity(activity)
            val type = Class.forName(BRIDGE_CLASS, true, activity.classLoader)
            credentialBridge = type.getMethod(
                "attach",
                AppCompatActivity::class.java,
                Any::class.java,
            ).invoke(null, activity, webView)
        }.onFailure {
            bridgeFailed = true
            credentialBridge = null
            unavailable()
        }
    }

    fun foregrounded() {
        runCatching {
            credentialBridge?.javaClass?.getMethod("foregrounded")?.invoke(credentialBridge)
        }
    }

    fun navigationStarted(url: String?) {
        invokeBridge("navigationStarted", url)
    }

    fun backgrounded() {
        runCatching {
            credentialBridge?.javaClass?.getMethod("backgrounded")?.invoke(credentialBridge)
        }
    }

    fun destroy() {
        runCatching { credentialBridge?.javaClass?.getMethod("destroy")?.invoke(credentialBridge) }
        credentialBridge = null
    }

    private fun invokeBridge(name: String, value: String?) {
        runCatching {
            credentialBridge?.javaClass?.getMethod(name, String::class.java)
                ?.invoke(credentialBridge, value)
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
                    .putExtra("xanh.sync.wpe", true),
            )
        }.onFailure { unavailable() }
    }

    private fun unavailable() {
        Toast.makeText(activity, R.string.sync_feature_unavailable, Toast.LENGTH_LONG).show()
    }

    companion object {
        private const val MODULE = "sync_feature_wpe"
        private const val ACTIVITY_CLASS = "io.github.lamppkk.xanhbrowser.lite.sync.SyncFeatureActivity"
        private const val BRIDGE_CLASS = "io.github.lamppkk.xanhbrowser.lite.sync.WpeCredentialBridge"
        private const val HISTORY_CLASS = "io.github.lamppkk.xanhbrowser.lite.sync.LiteHistoryRecorder"
        private const val REDIRECT_URI = "xanh-browser-wpe://accounts/oauth"
    }
}
