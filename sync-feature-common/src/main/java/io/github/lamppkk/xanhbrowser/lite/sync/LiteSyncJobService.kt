package io.github.lamppkk.xanhbrowser.lite.sync

import android.annotation.SuppressLint
import android.app.job.JobParameters
import android.app.job.JobService
import io.github.lamppkk.xanhbrowser.sync.AccountState
import io.github.lamppkk.xanhbrowser.sync.SyncReason
import io.github.lamppkk.xanhbrowser.sync.SyncStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

// Application Services brings WorkManager classes transitively, but this split
// removes every WorkManager initializer/service and uses only this fixed job.
@SuppressLint("SpecifyJobSchedulerIdRange")
class LiteSyncJobService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var runningJob: Job? = null

    override fun onStartJob(params: JobParameters): Boolean {
        runningJob?.cancel()
        runningJob = scope.launch {
            val coordinator = LiteSyncCoordinator.get(applicationContext)
            val reason = params.extras.getString(KEY_REASON)
                ?.let { runCatching { SyncReason.valueOf(it) }.getOrNull() }
                ?: SyncReason.SCHEDULED
            val shouldRetry = runCatching {
                if (coordinator.snapshot()?.accountState != AccountState.CONNECTED) return@runCatching false
                val (url, title) = coordinator.lastTab()
                val snapshot = coordinator.sync(reason, url, title)
                snapshot.status == SyncStatus.NETWORK_ERROR
            }.getOrDefault(true)
            if (isActive) jobFinished(params, shouldRetry)
            synchronized(this@LiteSyncJobService) { runningJob = null }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        runningJob?.cancel()
        runningJob = null
        return true
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        const val KEY_REASON = "xanh.sync.reason"
    }
}
