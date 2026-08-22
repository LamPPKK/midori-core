package io.github.lamppkk.xanhbrowser.lite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RendererRecoveryPolicyTest {
    @Test
    fun choosesFirstBoundedWebUrl() {
        assertEquals(
            "https://current.example/path",
            RendererRecoveryPolicy.selectUrl(
                "mailto:test@example.com",
                "https://current.example/path",
                "https://fallback.example/",
            ),
        )
    }

    @Test
    fun rejectsCredentialsInvalidPortsAndOversizedUrls() {
        assertNull(RendererRecoveryPolicy.selectUrl("https://user:secret@example.com/"))
        assertNull(RendererRecoveryPolicy.selectUrl("https://example.com:70000/"))
        assertNull(RendererRecoveryPolicy.selectUrl("https://example.com/" + "a".repeat(8_192)))
    }
}
