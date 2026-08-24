package io.github.lamppkk.xanhbrowser.lite

import android.app.Application

/** Installs process-wide System WebView interception before the first Activity is created. */
class XanhBrowserLiteApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AdBlockCoordinator.get(this).installDefaultServiceWorkerClient()
    }
}
