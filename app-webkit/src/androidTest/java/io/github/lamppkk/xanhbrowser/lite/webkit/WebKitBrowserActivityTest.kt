package io.github.lamppkk.xanhbrowser.lite.webkit

import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebKitBrowserActivityTest {
    @Test
    fun launchesWebKitEdition() {
        ActivityScenario.launch(WebKitBrowserActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                check(!activity.isFinishing)
            }
        }
    }
}
