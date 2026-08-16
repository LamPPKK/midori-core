package io.github.lamppkk.xanhbrowser.lite

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
            scenario.onActivity {
                assertEquals("https://example.com/restored", it.currentWebUrlForTest())
            }
        }
    }
}
