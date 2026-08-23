package io.github.lamppkk.xanhbrowser.lite

import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.lifecycle.Lifecycle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
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
    fun recreationRestoresSafeCurrentUrl() {
        ActivityScenario.launch(BrowserActivity::class.java).use { scenario ->
            scenario.onActivity { it.loadWebUrlForTest("https://example.com/restored") }
            scenario.recreate()
            assertCurrentUrlEventually(scenario, "https://example.com/restored")
        }
    }

    @Test
    fun rendererRecoveryIsForegroundAndOneShot() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val target = "https://example.com/renderer-recovery"
        ActivityScenario.launch(BrowserActivity::class.java).use { scenario ->
            scenario.onActivity { it.loadWebUrlForTest(target) }
            assertCurrentUrlEventually(scenario, target)
            val firstIdentity = awaitWebViewIdentity(scenario)

            terminateRendererEventually(scenario)
            val recoveredIdentity = awaitWebViewIdentity(scenario, differentFrom = firstIdentity)
            assertNotEquals(firstIdentity, recoveredIdentity)
            assertCurrentUrlEventually(scenario, target)
            scenario.onActivity { assertTrue(it.rendererRecoveryUsedForTest()) }

            terminateRendererEventually(scenario)
            awaitScenarioDestroyed(scenario)
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

    private fun awaitWebViewIdentity(
        scenario: ActivityScenario<BrowserActivity>,
        differentFrom: Int? = null,
    ): Int {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        var identity: Int? = null
        while (SystemClock.elapsedRealtime() < deadline) {
            scenario.onActivity { identity = it.currentWebViewIdentityForTest() }
            if (identity != null && identity != differentFrom) return requireNotNull(identity)
            SystemClock.sleep(50)
        }
        return requireNotNull(identity) { "A replacement WebView was not created" }
    }

    private fun terminateRendererEventually(scenario: ActivityScenario<BrowserActivity>) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        var terminated = false
        while (!terminated && SystemClock.elapsedRealtime() < deadline) {
            scenario.onActivity { terminated = it.terminateCurrentRendererForTest() }
            if (!terminated) SystemClock.sleep(50)
        }
        assertTrue("WebView renderer never became available", terminated)
    }

    private fun awaitScenarioDestroyed(scenario: ActivityScenario<BrowserActivity>) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (scenario.state != Lifecycle.State.DESTROYED && SystemClock.elapsedRealtime() < deadline) {
            SystemClock.sleep(50)
        }
        assertEquals(Lifecycle.State.DESTROYED, scenario.state)
    }
}
