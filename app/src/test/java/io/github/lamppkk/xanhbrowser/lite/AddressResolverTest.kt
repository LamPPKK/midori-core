package io.github.lamppkk.xanhbrowser.lite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AddressResolverTest {
    @Test
    fun keepsSecureUrl() {
        assertEquals("https://example.com/path", AddressResolver.resolve("https://example.com/path"))
    }

    @Test
    fun defaultsHostnameToHttps() {
        assertEquals("https://example.com", AddressResolver.resolve("example.com"))
    }

    @Test
    fun allowsLocalhostOverHttp() {
        assertEquals("http://localhost:8080", AddressResolver.resolve("localhost:8080"))
    }

    @Test
    fun searchesPlainText() {
        assertTrue(AddressResolver.resolve("xanh browser").startsWith("https://duckduckgo.com/?q=xanh%20browser"))
    }

    @Test
    fun doesNotExecuteJavascriptInput() {
        assertTrue(AddressResolver.resolve("javascript:alert(1)").startsWith("https://duckduckgo.com/"))
    }

    @Test
    fun searchesMalformedWebUrls() {
        assertTrue(AddressResolver.resolve("https://").startsWith("https://duckduckgo.com/"))
        assertTrue(!AddressResolver.isValidWebUrl("http:///missing-host"))
    }

    @Test
    fun recognizesOnlyAllowlistedExternalSchemes() {
        assertTrue(AddressResolver.isExternal("tel:+84123456789"))
        assertTrue(!AddressResolver.isExternal("intent://malicious"))
    }

    @Test
    fun incomingIntentsAcceptOnlyWebUrls() {
        assertEquals("https://example.com", AddressResolver.resolveWebIntent("https://example.com"))
        assertEquals(null, AddressResolver.resolveWebIntent("tel:+84123456789"))
        assertEquals(null, AddressResolver.resolveWebIntent("intent://malicious"))
    }
}
