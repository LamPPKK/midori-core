package io.github.lamppkk.xanhbrowser.lite.sync

import android.content.Context
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.net.Uri
import android.os.PersistableBundle
import androidx.core.net.toUri
import androidx.core.content.edit
import io.github.lamppkk.xanhbrowser.sync.AccountServer
import io.github.lamppkk.xanhbrowser.sync.AccountState
import io.github.lamppkk.xanhbrowser.sync.SyncConfiguration
import io.github.lamppkk.xanhbrowser.sync.SyncEngine
import io.github.lamppkk.xanhbrowser.sync.SyncReason
import io.github.lamppkk.xanhbrowser.sync.SyncSnapshot
import io.github.lamppkk.xanhbrowser.sync.XanhSyncRuntime
import mozilla.appservices.remotetabs.ClientRemoteTabs
import mozilla.appservices.remotetabs.RemoteTabRecord

internal class LiteSyncCoordinator private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    @Volatile private var runtime: XanhSyncRuntime? = null

    @Synchronized
    fun configure(
        server: AccountServer,
        clientId: String,
        redirectUri: String,
        deviceName: String,
    ): XanhSyncRuntime {
        val configuration = SyncConfiguration(server, clientId, redirectUri, deviceName)
        configuration.validate()
        runtime?.close()
        preferences.edit {
            putString(CLIENT_ID, clientId)
            putString(REDIRECT_URI, redirectUri)
            putString(DEVICE_NAME, deviceName)
            putString(ACCOUNTS_URL, (server as? AccountServer.SelfHosted)?.accountsUrl)
            putString(TOKEN_URL, (server as? AccountServer.SelfHosted)?.tokenServerUrl)
        }
        return XanhSyncRuntime(appContext, configuration)
            .also(::applyEnginePreferences)
            .also { runtime = it }
    }

    @Synchronized
    fun runtimeOrNull(): XanhSyncRuntime? {
        runtime?.let { return it }
        val configuration = storedConfiguration() ?: return null
        return runCatching { XanhSyncRuntime(appContext, configuration) }
            .getOrNull()
            ?.also(::applyEnginePreferences)
            .also { runtime = it }
    }

    fun beginOAuth(): String = requireNotNull(runtimeOrNull()).beginOAuth()

    fun completeOAuth(uri: Uri): AccountState {
        val expected = requireNotNull(preferences.getString(REDIRECT_URI, null)).toUri()
        require(uri.scheme == expected.scheme && uri.host == expected.host && uri.path == expected.path)
        return requireNotNull(runtimeOrNull()).completeOAuth(
            requireNotNull(uri.getQueryParameter("code")),
            requireNotNull(uri.getQueryParameter("state")),
        )
    }

    fun snapshot(): SyncSnapshot? = runtimeOrNull()?.snapshot()

    fun isDue(reason: SyncReason): Boolean = runtimeOrNull()?.isSyncDue(reason) == true

    fun setEngineEnabled(engine: SyncEngine, enabled: Boolean) {
        preferences.edit { putBoolean("$ENGINE_PREFIX${engine.name}", enabled) }
        runtimeOrNull()?.setEngineEnabled(engine, enabled)
    }

    suspend fun sync(reason: SyncReason, currentUrl: String?, currentTitle: String?): SyncSnapshot {
        val runtime = requireNotNull(runtimeOrNull())
        if (!runtime.isSyncDue(reason)) return runtime.snapshot()
        val webUrl = currentUrl?.takeIf(::isWebUrl)
        if (webUrl != null) {
            preferences.edit {
                putString(LAST_URL, webUrl)
                putString(LAST_TITLE, currentTitle.orEmpty())
            }
            runtime.setLocalTabs(
                listOf(
                    RemoteTabRecord(
                        title = currentTitle?.ifBlank { webUrl } ?: webUrl,
                        urlHistory = listOf(webUrl),
                        icon = null,
                        lastUsed = System.currentTimeMillis(),
                        inactive = false,
                        pinned = false,
                        index = 0u,
                        windowId = "",
                        tabGroupId = "",
                    ),
                ),
            )
        }
        return runtime.sync(reason)
    }

    fun recordCurrentVisit(url: String?, title: String?) {
        val webUrl = url?.takeIf(::isWebUrl) ?: return
        val active = runtimeOrNull() ?: return
        active.recordHistory(webUrl, title.orEmpty(), System.currentTimeMillis())
        active.recordLocalChange()
        scheduleLocalChange()
    }

    fun bookmarkCurrent(url: String?, title: String?): Boolean {
        val webUrl = url?.takeIf(::isWebUrl) ?: return false
        val active = runtimeOrNull() ?: return false
        active.saveBookmark(webUrl, title?.ifBlank { webUrl } ?: webUrl)
        active.recordLocalChange()
        scheduleLocalChange()
        return true
    }

    fun remoteTabs(): List<ClientRemoteTabs> = runtimeOrNull()?.remoteTabs().orEmpty()

    fun unlockVault() = requireNotNull(runtimeOrNull()).unlockVault()

    fun lockVault() = runtimeOrNull()?.lockVault()

    suspend fun disconnect(deleteLocal: Boolean) {
        val active = runtimeOrNull()
        active?.disconnect(deleteLocal)
        active?.close()
        synchronized(this) { runtime = null }
        (appContext.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).cancel(JOB_ID)
        (appContext.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).cancel(PRE_SLEEP_JOB_ID)
        (appContext.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).cancel(LOCAL_CHANGE_JOB_ID)
        if (deleteLocal) {
            XanhSyncRuntime.deleteLocalData(appContext)
            preferences.edit { clear() }
        }
    }

    fun schedule() {
        if (storedConfiguration() == null) return
        val job = JobInfo.Builder(JOB_ID, ComponentName(appContext, LiteSyncJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPeriodic(15 * 60 * 1_000L)
            .setPersisted(false)
            .build()
        (appContext.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).schedule(job)
    }

    fun schedulePreSleep() {
        if (snapshot()?.accountState != AccountState.CONNECTED) return
        scheduleOneOff(PRE_SLEEP_JOB_ID, SyncReason.PRE_SLEEP, minimumLatency = 0, deadline = 1_000)
    }

    private fun scheduleLocalChange() {
        if (snapshot()?.accountState != AccountState.CONNECTED) return
        scheduleOneOff(
            LOCAL_CHANGE_JOB_ID,
            SyncReason.LOCAL_CHANGE,
            minimumLatency = LOCAL_CHANGE_DEBOUNCE_MILLIS,
            deadline = LOCAL_CHANGE_DEBOUNCE_MILLIS + 5_000,
        )
    }

    private fun scheduleOneOff(id: Int, reason: SyncReason, minimumLatency: Long, deadline: Long) {
        val extras = PersistableBundle().apply {
            putString(LiteSyncJobService.KEY_REASON, reason.name)
        }
        val job = JobInfo.Builder(id, ComponentName(appContext, LiteSyncJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setMinimumLatency(minimumLatency)
            .setOverrideDeadline(deadline)
            .setExtras(extras)
            .setPersisted(false)
            .build()
        (appContext.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).schedule(job)
    }

    fun lastTab(): Pair<String?, String?> =
        preferences.getString(LAST_URL, null) to preferences.getString(LAST_TITLE, null)

    private fun storedConfiguration(): SyncConfiguration? {
        val clientId = preferences.getString(CLIENT_ID, null) ?: return null
        val redirectUri = preferences.getString(REDIRECT_URI, null) ?: return null
        val deviceName = preferences.getString(DEVICE_NAME, null) ?: return null
        val accounts = preferences.getString(ACCOUNTS_URL, null)
        val token = preferences.getString(TOKEN_URL, null)
        val server = if (accounts != null && token != null) {
            AccountServer.SelfHosted(accounts, token)
        } else {
            AccountServer.Mozilla
        }
        return SyncConfiguration(server, clientId, redirectUri, deviceName)
    }

    private fun applyEnginePreferences(runtime: XanhSyncRuntime) {
        SyncEngine.entries.forEach { engine ->
            runtime.setEngineEnabled(
                engine,
                preferences.getBoolean("$ENGINE_PREFIX${engine.name}", true),
            )
        }
    }

    private fun isWebUrl(value: String): Boolean = runCatching {
        val uri = value.toUri()
        (uri.scheme == "https" || uri.scheme == "http") && !uri.host.isNullOrBlank() && uri.userInfo == null
    }.getOrDefault(false)

    companion object {
        private const val PREFERENCES = "xanh_lite_sync"
        private const val CLIENT_ID = "client_id"
        private const val REDIRECT_URI = "redirect_uri"
        private const val DEVICE_NAME = "device_name"
        private const val ACCOUNTS_URL = "accounts_url"
        private const val TOKEN_URL = "token_url"
        private const val ENGINE_PREFIX = "engine_"
        private const val LAST_URL = "last_url"
        private const val LAST_TITLE = "last_title"
        private const val JOB_ID = 0x584653
        private const val PRE_SLEEP_JOB_ID = 0x584654
        private const val LOCAL_CHANGE_JOB_ID = 0x584655
        private const val LOCAL_CHANGE_DEBOUNCE_MILLIS = 30_000L
        @Volatile private var instance: LiteSyncCoordinator? = null

        fun get(context: Context): LiteSyncCoordinator = instance ?: synchronized(this) {
            instance ?: LiteSyncCoordinator(context).also { instance = it }
        }
    }
}
