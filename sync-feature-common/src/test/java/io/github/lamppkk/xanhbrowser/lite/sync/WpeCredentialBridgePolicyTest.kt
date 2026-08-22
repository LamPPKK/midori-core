package io.github.lamppkk.xanhbrowser.lite.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WpeCredentialBridgePolicyTest {
    @Test
    fun acceptsOnlyCanonicalizableHttpsDocuments() {
        assertEquals(
            "https://example.com/login?next=%2Fhome",
            WpeCredentialBridgePolicy.canonicalHttpsUrl(
                "https://example.com/login?next=%2Fhome",
            ),
        )
        assertNull(WpeCredentialBridgePolicy.canonicalHttpsUrl("http://example.com/login"))
        assertNull(WpeCredentialBridgePolicy.canonicalHttpsUrl("https://user@example.com/login"))
        assertNull(WpeCredentialBridgePolicy.canonicalHttpsUrl("https://example.com:99999/login"))
        assertNull(WpeCredentialBridgePolicy.canonicalHttpsUrl("https:\\evil.example/login"))
    }

    @Test
    fun parsesOnlyStrictBoundedCredentialRequests() {
        val valid = """
            {
              "tabId": 1,
              "navigationGeneration": 7,
              "navigationChallenge": "ffeeddccbbaa99887766554433221100",
              "navigationNonce": "00112233445566778899aabbccddeeff",
              "requestId": "11223344556677889900aabbccddeeff",
              "sourceOrigin": "https://example.com",
              "messageType": "credential-request"
            }
        """.trimIndent()
        assertEquals(
            WpeCredentialRequest(
                1,
                7,
                "ffeeddccbbaa99887766554433221100",
                "00112233445566778899aabbccddeeff",
                "11223344556677889900aabbccddeeff",
                "https://example.com",
                "credential-request",
            ),
            WpeCredentialBridgePolicy.parseRequest(valid),
        )
        assertNull(
            WpeCredentialBridgePolicy.parseRequest(
                valid.replace("\"tabId\": 1", "\"tabId\": 1.5"),
            ),
        )
        assertNull(
            WpeCredentialBridgePolicy.parseRequest(
                valid.replace(
                    "\"messageType\": \"credential-request\"",
                    "\"messageType\": \"credential-request\", \"extra\": true",
                ),
            ),
        )
        assertNull(
            WpeCredentialBridgePolicy.parseRequest(
                valid.replace("00112233445566778899aabbccddeeff", "not-a-nonce"),
            ),
        )
        assertNull(WpeCredentialBridgePolicy.parseRequest("x".repeat(4_097)))
    }

    @Test
    fun bootstrapRequiresTopFrameTrustedGestureAndTypedReply() {
        val script = WpeCredentialBridgePolicy.bootstrapScript()
        assertTrue(script.contains("window.top !== window"))
        assertTrue(script.contains("event.isTrusted"))
        assertTrue(script.contains("globalThis.crypto.getRandomValues"))
        assertTrue(script.contains("globalThis.__xanhBindDocument"))
        assertTrue(script.contains("navigationChallenge"))
        assertTrue(script.contains("expectedRequestId !== requestedForId"))
        assertTrue(script.contains("expectedOrigin !== location.origin"))
        assertTrue(script.contains("document.visibilityState !== 'visible'"))
        assertTrue(script.contains("sourceOrigin: location.origin"))
        assertTrue(script.contains("send('credential-request', requestedForId)"))
        assertTrue(script.contains("globalThis.__xanhAcceptCredential = ("))
        assertTrue(script.contains("return true"))
        assertFalse(script.contains("JSON.parse"))
        assertFalse(script.contains("evaluateJavascript"))
        assertTrue(WpeCredentialBridgePolicy.bootstrapFunctionBody().startsWith("return (() =>"))
    }

    @Test
    fun validatesNonceMessageTypeAndExactLiveOrigin() {
        val request = WpeCredentialRequest(
            1,
            7,
            "ffeeddccbbaa99887766554433221100",
            "00112233445566778899aabbccddeeff",
            "11223344556677889900aabbccddeeff",
            "https://example.com",
            "credential-request",
        )
        assertTrue(
            WpeCredentialBridgePolicy.validateRequest(
                request,
                1,
                7,
                request.navigationChallenge,
                request.navigationNonce,
                "https://example.com/login",
                "credential-request",
            ),
        )
        assertFalse(
            WpeCredentialBridgePolicy.validateRequest(
                request.copy(sourceOrigin = "https://other.example"),
                1,
                7,
                request.navigationChallenge,
                request.navigationNonce,
                "https://example.com/login",
                "credential-request",
            ),
        )
        assertFalse(
            WpeCredentialBridgePolicy.validateRequest(
                request,
                1,
                7,
                request.navigationChallenge,
                "ffeeddccbbaa99887766554433221100",
                "https://example.com/login",
                "credential-request",
            ),
        )
        assertFalse(
            WpeCredentialBridgePolicy.validateRequest(
                request.copy(messageType = "credential-save"),
                1,
                7,
                request.navigationChallenge,
                request.navigationNonce,
                "https://example.com/login",
                "credential-request",
            ),
        )
        assertFalse(
            WpeCredentialBridgePolicy.validateRequest(
                request.copy(navigationGeneration = 6),
                1,
                7,
                request.navigationChallenge,
                request.navigationNonce,
                "https://example.com/login",
                "credential-request",
            ),
        )
        assertFalse(
            WpeCredentialBridgePolicy.validateRequest(
                request.copy(navigationChallenge = "abcdefabcdefabcdefabcdefabcdefab"),
                1,
                7,
                request.navigationChallenge,
                request.navigationNonce,
                "https://example.com/login",
                "credential-request",
            ),
        )
    }

    @Test
    fun readyHandshakeMustCarryCurrentHostChallenge() {
        val ready = WpeCredentialRequest(
            1,
            11,
            "ffeeddccbbaa99887766554433221100",
            "00112233445566778899aabbccddeeff",
            "00112233445566778899aabbccddeeff",
            "https://example.com",
            "bridge-ready",
        )
        assertTrue(
            WpeCredentialBridgePolicy.validateReady(
                ready,
                1,
                11,
                ready.navigationChallenge,
                "https://example.com/login",
            ),
        )
        assertFalse(
            WpeCredentialBridgePolicy.validateReady(
                ready.copy(navigationChallenge = "abcdefabcdefabcdefabcdefabcdefab"),
                1,
                11,
                ready.navigationChallenge,
                "https://example.com/login",
            ),
        )
        assertFalse(
            WpeCredentialBridgePolicy.validateReady(
                ready.copy(requestId = "11223344556677889900aabbccddeeff"),
                1,
                11,
                ready.navigationChallenge,
                "https://example.com/login",
            ),
        )
    }
}
