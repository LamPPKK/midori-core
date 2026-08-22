package io.github.lamppkk.xanhbrowser.lite.webkit

import org.junit.Assert.assertEquals
import org.junit.Test

class WebKitNavigationPolicyTest {
    @Test
    fun allowsOnlyWebContentAndTheEmptyBootstrapPage() {
        assertDecision(WebKitNavigationDecision.ALLOW, "https://webkit.org/", false, false)
        assertDecision(WebKitNavigationDecision.ALLOW, "about:blank", false, false)
        assertDecision(WebKitNavigationDecision.BLOCK, "file:///tmp/private", false, true)
        assertDecision(WebKitNavigationDecision.BLOCK, "javascript:alert(1)", false, true)
    }

    @Test
    fun externalSchemesRequireANonRedirectedUserGesture() {
        assertDecision(WebKitNavigationDecision.OPEN_EXTERNAL, "mailto:user@example.com", false, true)
        assertDecision(WebKitNavigationDecision.OPEN_EXTERNAL, "tel:+84123456789", false, true)
        assertDecision(WebKitNavigationDecision.BLOCK, "mailto:user@example.com", false, false)
        assertDecision(WebKitNavigationDecision.BLOCK, "market://details?id=example", true, true)
        assertDecision(WebKitNavigationDecision.BLOCK, "intent://example/#Intent;end", false, true)
    }

    private fun assertDecision(
        expected: WebKitNavigationDecision,
        url: String,
        isRedirect: Boolean,
        hasUserGesture: Boolean,
    ) {
        assertEquals(expected, WebKitNavigationPolicy.decide(url, isRedirect, hasUserGesture))
    }
}
