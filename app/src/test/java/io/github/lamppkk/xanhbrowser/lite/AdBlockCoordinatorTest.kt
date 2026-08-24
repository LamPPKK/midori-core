package io.github.lamppkk.xanhbrowser.lite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AdBlockCoordinatorTest {
    @Test fun `content blocking defaults on`() {
        assertTrue(AdBlockCoordinator.DEFAULT_ENABLED)
    }

    @Test fun `native ABI version must match exactly`() {
        val exact = (NativeAdBlockMatcher.EXPECTED_VERSION + "\u0000").toByteArray()
        assertTrue(NativeAdBlockMatcher.acceptsVersionBytes(exact))
        assertFalse(
            NativeAdBlockMatcher.acceptsVersionBytes(
                (NativeAdBlockMatcher.EXPECTED_VERSION + ".1\u0000").toByteArray(),
            ),
        )
        assertFalse(
            NativeAdBlockMatcher.acceptsVersionBytes(
                NativeAdBlockMatcher.EXPECTED_VERSION.toByteArray(),
            ),
        )
    }

    @Test fun `main frame is always allowed before matcher invocation`() {
        var invoked = false
        val matcher = AdBlockMatcher { invoked = true; true }
        val host = AdBlockHost(enabled = { true }, fallbackMatcher = matcher)

        assertFalse(
            host.shouldBlock(
                targetUrl = "https://doubleclick.net/page",
                sourceUrl = "https://example.com/",
                isForMainFrame = true,
                method = "GET",
                headers = emptyMap(),
            ),
        )
        assertFalse(invoked)
    }

    @Test fun `request inference prefers fetch destination and normalizes method`() {
        val request = AdBlockRequestPolicy.create(
            targetUrl = "https://cdn.example/opaque",
            sourceUrl = "https://example.com/page",
            isForMainFrame = false,
            method = "GET",
            headers = mapOf("sec-fetch-dest" to "script", "Accept" to "*/*"),
        )

        requireNotNull(request)
        assertEquals(AdBlockResourceType.SCRIPT, request.resourceType)
        assertEquals("get", request.method)
        assertEquals("cdn.example", request.targetHost)
        assertEquals("https://example.com/page", request.sourceUrl)
        assertEquals("example.com", request.sourceHost)
    }

    @Test fun `request inference falls back to accept then extension`() {
        val image = AdBlockRequestPolicy.create(
            "https://cdn.example/no-extension",
            null,
            false,
            "GET",
            mapOf("ACCEPT" to "image/avif,image/webp,*/*"),
        )
        val stylesheet = AdBlockRequestPolicy.create(
            "https://cdn.example/site.CSS?version=2",
            null,
            false,
            "GET",
            emptyMap(),
        )

        assertEquals(AdBlockResourceType.IMAGE, image?.resourceType)
        assertEquals("https://cdn.example/no-extension", image?.sourceUrl)
        assertEquals("cdn.example", image?.sourceHost)
        assertEquals(AdBlockResourceType.STYLESHEET, stylesheet?.resourceType)
    }

    @Test fun `oversized target stays outside native boundary and host remains usable`() {
        val oversized = "https://doubleclick.net/ad.js?" +
            "a".repeat(AdBlockRequestPolicy.MAX_URL_BYTES)
        val fallback = BundledAbpDomainMatcher.fromText("||doubleclick.net^")

        assertNull(AdBlockRequestPolicy.create(oversized, null, false, "GET", emptyMap()))
        assertTrue(AdBlockRequestPolicy.exceedsNativeUrlLimit(oversized))
        assertEquals(
            "doubleclick.net",
            AdBlockRequestPolicy.normalizeFallbackHost("DoubleClick.NET."),
        )
        assertTrue(fallback.shouldBlockHosts("doubleclick.net", "publisher.example"))
    }

    @Test fun `invalid and oversized source become conservatively first party`() {
        val oversized = "https://example.com/" +
            "a".repeat(AdBlockRequestPolicy.MAX_URL_BYTES)
        val request = AdBlockRequestPolicy.create(
            "https://doubleclick.net/ad.js",
            oversized,
            false,
            "GET",
            emptyMap(),
        )

        assertEquals("https://doubleclick.net/ad.js", request?.sourceUrl)
        assertEquals("doubleclick.net", request?.sourceHost)
        assertNull(AdBlockRequestPolicy.sourceHostForFallback(oversized))
    }

    @Test fun `failed native matcher retains bounded fallback protection`() {
        val fallback = BundledAbpDomainMatcher.fromText("||doubleclick.net^")
        val host = AdBlockHost(
            enabled = { true },
            fallbackMatcher = fallback,
            matcher = AdBlockMatcher { throw IllegalStateException("native failure") },
        )

        assertTrue(
            host.shouldBlock(
                "https://doubleclick.net/advert.js",
                "https://publisher.example/",
                false,
                "GET",
                emptyMap(),
            ),
        )
    }

    @Test fun `disabled host permits requests`() {
        val fallback = AdBlockMatcher { true }
        val host = AdBlockHost(enabled = { false }, fallbackMatcher = fallback)

        assertFalse(
            host.shouldBlock(
                "https://doubleclick.net/ad.js",
                "https://publisher.example/",
                false,
                "GET",
                emptyMap(),
            ),
        )
    }

    @Test fun `bounded domain matcher blocks exact and subdomains but honors exception`() {
        val matcher = BundledAbpDomainMatcher.fromText(
            """
            ||doubleclick.net^
            ||ads.example^
            @@||allowed.ads.example^
            """.trimIndent(),
        )

        assertTrue(matcher.shouldBlock(request("doubleclick.net")))
        assertTrue(matcher.shouldBlock(request("media.doubleclick.net")))
        assertTrue(matcher.shouldBlock(request("ads.example")))
        assertFalse(matcher.shouldBlock(request("allowed.ads.example")))
        assertFalse(matcher.shouldBlock(request("notdoubleclick.net")))
    }

    @Test fun `third party domain rule needs a cross site source`() {
        val matcher = BundledAbpDomainMatcher.fromText(
            "||connect.facebook.net^\$third-party",
        )

        assertTrue(matcher.shouldBlock(request("connect.facebook.net", "publisher.example")))
        assertFalse(matcher.shouldBlock(request("connect.facebook.net", "www.facebook.net")))
        assertFalse(matcher.shouldBlock(request("connect.facebook.net", null)))
    }

    @Test fun `unsupported scheme and invalid method fail open`() {
        assertNull(
            AdBlockRequestPolicy.create(
                "file:///tmp/ad.js",
                "https://example.com/",
                false,
                "GET",
                emptyMap(),
            ),
        )
        assertNull(
            AdBlockRequestPolicy.create(
                "https://doubleclick.net/ad.js",
                "https://example.com/",
                false,
                "GET\nDELETE",
                emptyMap(),
            ),
        )
    }

    private fun request(host: String, sourceHost: String? = "publisher.example"): AdBlockMatchRequest {
        val normalizedSourceHost = sourceHost ?: host
        return AdBlockMatchRequest(
            targetUrl = "https://$host/ad.js",
            sourceUrl = "https://$normalizedSourceHost/",
            targetHost = host,
            sourceHost = normalizedSourceHost,
            resourceType = AdBlockResourceType.SCRIPT,
            method = "get",
        )
    }
}
