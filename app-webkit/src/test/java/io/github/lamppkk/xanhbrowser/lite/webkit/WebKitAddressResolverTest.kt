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
        assertEquals(WebKitAddressResolver.HOME_URL, WebKitAddressResolver.resolve("a".repeat(8_193)))
        assertEquals(WebKitAddressResolver.HOME_URL, WebKitAddressResolver.resolve("😀".repeat(1_000)))
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
        assertFalse(WebKitAddressResolver.isExternal("mailto:\nuser@example.com"))
        assertFalse(WebKitAddressResolver.isExternal("mailto:user@example.com?subject=x%0d%0aBcc:test@example.com"))
        assertFalse(WebKitAddressResolver.isExternal("tel:%00+84123456789"))
        assertFalse(WebKitAddressResolver.isExternal("tel:"))
        assertTrue(WebKitAddressResolver.isValidWebUrl("https://example.com"))
        assertFalse(WebKitAddressResolver.isValidWebUrl("file:///tmp/private"))
        assertFalse(WebKitAddressResolver.isValidWebUrl("https://user:secret@example.com"))
        assertFalse(WebKitAddressResolver.isValidWebUrl("https://example.com/\nspoof"))
        assertFalse(WebKitAddressResolver.isValidWebUrl("https://example.com/${"a".repeat(8_193)}"))
        assertFalse(WebKitAddressResolver.isValidWebUrl("https://example.com:70000/"))
    }
}
