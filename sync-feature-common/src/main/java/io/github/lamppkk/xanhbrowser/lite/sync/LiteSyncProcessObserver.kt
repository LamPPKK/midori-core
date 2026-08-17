package io.github.lamppkk.xanhbrowser.lite.sync

import android.app.Application
import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper

internal object LiteSyncProcessObserver : Application.ActivityLifecycleCallbacks {
    @Volatile private var installed = false
    private var application: Application? = null
    private var startedActivities = 0
    private val handler = Handler(Looper.getMainLooper())
    private val lockVault = Runnable {
        application?.let {
            LiteSyncCoordinator.get(it).apply {
                lockVault()
                schedulePreSleep()
            }
        }
    }

    @Synchronized
    fun install(application: Application) {
        if (installed) return
        this.application = application
        application.registerActivityLifecycleCallbacks(this)
        installed = true
    }

    override fun onActivityStarted(activity: Activity) {
        handler.removeCallbacks(lockVault)
        startedActivities++
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities = (startedActivities - 1).coerceAtLeast(0)
        if (startedActivities == 0) handler.postDelayed(lockVault, BACKGROUND_SETTLE_MILLIS)
    }

    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit

    private const val BACKGROUND_SETTLE_MILLIS = 500L
}
