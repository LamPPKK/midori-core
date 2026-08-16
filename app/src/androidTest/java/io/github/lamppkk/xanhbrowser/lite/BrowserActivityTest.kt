package io.github.lamppkk.xanhbrowser.lite

import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BrowserActivityTest {
    @Test
    fun launchesBrowserActivity() {
        ActivityScenario.launch(BrowserActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> check(!activity.isFinishing) }
        }
    }

    @Test
    fun recreationRestoresCurrentWebViewState() {
        ActivityScenario.launch(BrowserActivity::class.java).use { scenario ->
            scenario.onActivity { it.loadWebUrlForTest("https://example.com/restored") }
            scenario.recreate()
            assertCurrentUrlEventually(scenario, "https://example.com/restored")
        }
    }

    private fun assertCurrentUrlEventually(
        scenario: ActivityScenario<BrowserActivity>,
        expected: String,
    ) {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        var actual: String? = null
        while (SystemClock.elapsedRealtime() < deadline) {
            scenario.onActivity { actual = it.currentWebUrlForTest() }
            if (actual == expected) return
            SystemClock.sleep(100)
        }
        assertEquals(expected, actual)
    }
}
