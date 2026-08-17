package io.github.lamppkk.xanhbrowser.lite.sync

import android.content.Context

/** Reflection entry point used by both Lite browser bases after the split is installed. */
object LiteHistoryRecorder {
    @JvmStatic
    fun record(context: Context, url: String?, title: String?) {
        LiteSyncCoordinator.get(context).recordCurrentVisit(url, title)
    }
}
