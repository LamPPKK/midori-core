package io.github.lamppkk.xanhbrowser.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

class PortableBackupTest {
    private val payload = PortableBackupPayload(
        createdAtEpochMillis = 1_700_000_000_000,
        sourceEdition = "android-lite-webkit",
        urls = listOf("https://example.com/", "https://webkit.org/"),
        selectedIndex = 1,
        desktopSite = true,
    )

    @Test
    fun encryptedBackupRoundTrips() {
        val password = "correct horse battery staple".toCharArray()
        val encoded = PortableBackup.encode(payload, password)
        assertEquals(payload, PortableBackup.decode(encoded, password))
    }

    @Test
    fun matchesPortableGoldenVector() {
        val expectedBase64 =
            "WEFOSEJLMQAAAAABAAM0UAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhsAAABrGe+1+LCSaxIIZoTehQCW/YIh3t1cWKdtm2ZRhz5KDI1ss8rhvNIL709BNuA0TcxI/6UIxeKecxM6+ofiMw3m0Ij51SZIl9KKSASqMcyXCRVDgSnVBCrcAKURj7URBqlSOW181AoYQXA+Aiw="
        val encoded = PortableBackup.encode(
            payload,
            "correct horse battery staple".toCharArray(),
            ByteArray(16) { it.toByte() },
            ByteArray(12) { (it + 16).toByte() },
        )
        assertEquals(
            expectedBase64,
            Base64.getEncoder().encodeToString(encoded),
        )
        assertEquals(
            payload,
            PortableBackup.decode(
                Base64.getDecoder().decode(expectedBase64),
                "correct horse battery staple".toCharArray(),
            ),
        )
    }

    @Test
    fun matchesUnicodePasswordGoldenVector() {
        val encoded = PortableBackup.encode(
            payload,
            "mật-khẩu-Xanh-🔒".toCharArray(),
            ByteArray(16) { it.toByte() },
            ByteArray(12) { (it + 16).toByte() },
        )
        assertEquals(
            "WEFOSEJLMQAAAAABAAM0UAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhsAAABrfjICD8Mjv9vFJ0zWrTRPQSUTvi8TnvUo1avIYeQ5ehuR/ZrSJ6l/mE8DpJJ/RyRFfKbZF6I+GbB2zRIFF8M//fuYuJSK/3/0K0dBM0CnXITV+mXV4Z6zOoIAxLCvs/QXPJTSiUKgBg/XtVE=",
            Base64.getEncoder().encodeToString(encoded),
        )
    }

    @Test
    fun rejectsWrongPasswordAndTampering() {
        val encoded = PortableBackup.encode(payload, "correct password".toCharArray())
        assertThrows(IllegalArgumentException::class.java) {
            PortableBackup.decode(encoded, "wrong password".toCharArray())
        }

        encoded[encoded.lastIndex] = (encoded.last().toInt() xor 1).toByte()
        assertThrows(IllegalArgumentException::class.java) {
            PortableBackup.decode(encoded, "correct password".toCharArray())
        }
    }

    @Test
    fun rejectsUnsafeUrls() {
        listOf("file:///private/data", "https://user:secret@example.com/").forEach { unsafeUrl ->
            assertThrows(IllegalArgumentException::class.java) {
                PortableBackup.encode(
                    payload.copy(urls = listOf(unsafeUrl), selectedIndex = 0),
                    "correct password".toCharArray(),
                )
            }
        }
    }
}
