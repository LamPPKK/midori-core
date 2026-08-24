package io.github.lamppkk.xanhbrowser.lite.webkit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class XanhWebViewContractTest {
    @Test
    fun publishedPreviewDoesNotClaimForkOnlyCapabilities() {
        val info = XanhWebViewContract.engineInfo(sourceFork = false)

        assertEquals("0.1.0-alpha.1", info.apiVersion)
        assertEquals("wpe-android", info.backendId)
        assertFalse(info.sourceFork)
        assertFalse("preload-navigation-policy" in info.capabilities)
        assertFalse("ephemeral-profile" in info.capabilities)
        assertTrue("tls-fail-closed" in info.capabilities)
    }

    @Test
    fun sourceForkAdvertisesOnlyReviewedCapabilities() {
        val info = XanhWebViewContract.engineInfo(sourceFork = true)

        assertTrue(info.sourceFork)
        assertTrue("preload-navigation-policy" in info.capabilities)
        assertTrue("named-isolated-script-world" in info.capabilities)
        assertTrue("typed-script-messages" in info.capabilities)
    }
}
