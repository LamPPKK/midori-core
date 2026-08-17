package io.github.lamppkk.xanhbrowser.lite.webkit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebKitAddressResolverTest {
    @Test
    fun resolvesHostAndSearchInput() {
        assertEquals("https://webkit.org", WebKitAddressResolver.resolve("webkit.org"))
        assertTrue(WebKitAddressResolver.resolve("xanh browser").startsWith("https://duckduckgo.com/?q="))
        assertEquals(WebKitAddressResolver.HOME_URL, WebKitAddressResolver.resolve(""))
    }

    @Test
    fun acceptsOnlyValidWebDeepLinks() {
        assertEquals(
            "https://example.com/path",
            WebKitAddressResolver.resolveWebIntent("https://example.com/path"),
        )
        assertNull(WebKitAddressResolver.resolveWebIntent("mailto:user@example.com"))
        assertNull(WebKitAddressResolver.resolveWebIntent("https:///missing-host"))
    }

    @Test
    fun separatesExternalSchemesFromWebContent() {
        assertTrue(WebKitAddressResolver.isExternal("tel:+84123456789"))
        assertFalse(WebKitAddressResolver.isExternal("https://example.com"))
        assertTrue(WebKitAddressResolver.isValidWebUrl("https://example.com"))
        assertFalse(WebKitAddressResolver.isValidWebUrl("file:///tmp/private"))
    }
}
