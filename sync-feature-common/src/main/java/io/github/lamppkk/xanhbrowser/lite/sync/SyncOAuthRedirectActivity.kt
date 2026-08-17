package io.github.lamppkk.xanhbrowser.lite.sync

import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SyncOAuthRedirectActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val callback = intent.data
        if (callback == null) {
            finish()
            return
        }
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { LiteSyncCoordinator.get(this@SyncOAuthRedirectActivity).completeOAuth(callback) }
            }
            if (result.isFailure) {
                Toast.makeText(this@SyncOAuthRedirectActivity, R.string.sync_failed, Toast.LENGTH_LONG).show()
            } else {
                LiteSyncCoordinator.get(this@SyncOAuthRedirectActivity).schedule()
            }
            finish()
        }
    }
}
