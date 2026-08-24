package io.github.lamppkk.xanhbrowser.lite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class XanhWebViewContractTest {
    @Test
    fun systemProviderRemainsAnExplicitFallback() {
        val info = XanhWebViewContract.engineInfo

        assertEquals("0.1.0-alpha.1", info.apiVersion)
        assertEquals("android-system-webview", info.backendId)
        assertEquals("wpe-android", info.replacementTarget)
        assertTrue(info.isFallback)
    }
}
