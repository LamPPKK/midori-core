package io.github.lamppkk.xanhbrowser.backup

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

data class PortableBackupPayload(
    val createdAtEpochMillis: Long,
    val sourceEdition: String,
    val urls: List<String>,
    val selectedIndex: Int,
    val desktopSite: Boolean,
)

object PortableBackup {
    const val MIME_TYPE = "application/vnd.xanh-browser.backup"
    const val FILE_EXTENSION = ".xanhbackup"
    const val MAX_ENCODED_BYTES = 1_048_576

    private val magic = byteArrayOf(0x58, 0x41, 0x4E, 0x48, 0x42, 0x4B, 0x31, 0x00)
    private const val FORMAT_VERSION = 1
    private const val PAYLOAD_VERSION = 1
    private const val ITERATIONS = 210_000
    private const val KEY_BITS = 256
    private const val SALT_BYTES = 16
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128
    private const val TAG_BYTES = TAG_BITS / 8
    private const val MAX_URLS = 50
    private const val MAX_STRING_BYTES = 4_096

    fun encode(payload: PortableBackupPayload, passphrase: CharArray): ByteArray {
        val random = SecureRandom()
        return encode(payload, passphrase, ByteArray(SALT_BYTES).also(random::nextBytes), ByteArray(NONCE_BYTES).also(random::nextBytes))
    }

    internal fun encode(
        payload: PortableBackupPayload,
        passphrase: CharArray,
        salt: ByteArray,
        nonce: ByteArray,
    ): ByteArray {
        validatePassphrase(passphrase)
        require(salt.size == SALT_BYTES) { "Invalid backup salt" }
        require(nonce.size == NONCE_BYTES) { "Invalid backup nonce" }

        val plaintext = encodePayload(payload)
        val key = deriveKey(passphrase, salt, ITERATIONS)
        val encrypted = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
                doFinal(plaintext)
            }
        } finally {
            key.fill(0)
            plaintext.fill(0)
        }

        return ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.write(magic)
                output.writeInt(FORMAT_VERSION)
                output.writeInt(ITERATIONS)
                output.write(salt)
                output.write(nonce)
                output.writeInt(encrypted.size)
                output.write(encrypted)
            }
            bytes.toByteArray()
        }.also {
            require(it.size <= MAX_ENCODED_BYTES) { "Backup is too large" }
        }
    }

    fun decode(encoded: ByteArray, passphrase: CharArray): PortableBackupPayload {
        validatePassphrase(passphrase)
        require(encoded.size in minimumFileSize()..MAX_ENCODED_BYTES) { "Invalid backup size" }

        return DataInputStream(ByteArrayInputStream(encoded)).use { input ->
            require(readExact(input, magic.size).contentEquals(magic)) { "Not a Xanh Browser backup" }
            require(input.readInt() == FORMAT_VERSION) { "Unsupported backup version" }
            val iterations = input.readInt()
            require(iterations in 100_000..1_000_000) { "Invalid backup key settings" }
            val salt = readExact(input, SALT_BYTES)
            val nonce = readExact(input, NONCE_BYTES)
            val encryptedSize = input.readInt()
            require(encryptedSize in TAG_BYTES..MAX_ENCODED_BYTES && encryptedSize == input.available()) {
                "Invalid backup payload size"
            }
            val encrypted = readExact(input, encryptedSize)
            val key = deriveKey(passphrase, salt, iterations)
            val plaintext = try {
                Cipher.getInstance("AES/GCM/NoPadding").run {
                    init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
                    doFinal(encrypted)
                }
            } catch (_: AEADBadTagException) {
                throw IllegalArgumentException("Wrong password or damaged backup")
            } finally {
                key.fill(0)
                encrypted.fill(0)
            }

            try {
                decodePayload(plaintext)
            } finally {
                plaintext.fill(0)
            }
        }
    }

    private fun encodePayload(payload: PortableBackupPayload): ByteArray {
        require(payload.createdAtEpochMillis >= 0) { "Invalid backup date" }
        require(payload.sourceEdition.isNotBlank()) { "Missing source edition" }
        require(payload.urls.isNotEmpty() && payload.urls.size <= MAX_URLS) { "Invalid tab count" }
        require(payload.selectedIndex in payload.urls.indices) { "Invalid selected tab" }
        payload.urls.forEach { require(isSupportedWebUrl(it)) { "Backup contains an unsafe URL" } }

        return ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(PAYLOAD_VERSION)
                output.writeLong(payload.createdAtEpochMillis)
                writeString(output, payload.sourceEdition)
                output.writeInt(payload.selectedIndex)
                output.writeByte(if (payload.desktopSite) 1 else 0)
                output.writeInt(payload.urls.size)
                payload.urls.forEach { writeString(output, it) }
            }
            bytes.toByteArray()
        }
    }

    private fun decodePayload(plaintext: ByteArray): PortableBackupPayload =
        DataInputStream(ByteArrayInputStream(plaintext)).use { input ->
            require(input.readInt() == PAYLOAD_VERSION) { "Unsupported backup payload" }
            val createdAt = input.readLong()
            require(createdAt >= 0) { "Invalid backup date" }
            val source = readString(input)
            require(source.isNotBlank()) { "Missing source edition" }
            val selectedIndex = input.readInt()
            val flags = input.readUnsignedByte()
            require(flags and 0xFE == 0) { "Unsupported backup settings" }
            val count = input.readInt()
            require(count in 1..MAX_URLS) { "Invalid tab count" }
            val urls = List(count) { readString(input) }
            require(urls.all(::isSupportedWebUrl)) { "Backup contains an unsafe URL" }
            require(selectedIndex in urls.indices) { "Invalid selected tab" }
            require(input.available() == 0) { "Unexpected data after backup payload" }
            PortableBackupPayload(createdAt, source, urls, selectedIndex, flags and 1 != 0)
        }

    private fun writeString(output: DataOutputStream, value: String) {
        val encoded = value.toByteArray(StandardCharsets.UTF_8)
        require(encoded.isNotEmpty() && encoded.size <= MAX_STRING_BYTES) { "Invalid backup text" }
        output.writeInt(encoded.size)
        output.write(encoded)
    }

    private fun readString(input: DataInputStream): String {
        val length = input.readInt()
        require(length in 1..MAX_STRING_BYTES && length <= input.available()) { "Invalid backup text" }
        return String(readExact(input, length), StandardCharsets.UTF_8)
    }

    private fun readExact(input: DataInputStream, length: Int): ByteArray =
        ByteArray(length).also(input::readFully)

    private fun deriveKey(passphrase: CharArray, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(passphrase, salt, iterations, KEY_BITS)
        return try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }

    private fun validatePassphrase(passphrase: CharArray) {
        require(passphrase.size in 8..1_024) { "Backup password must contain at least 8 characters" }
    }

    fun isSupportedWebUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme?.lowercase() in setOf("http", "https") &&
            !uri.host.isNullOrBlank() &&
            uri.userInfo == null
    }.getOrDefault(false)

    private fun minimumFileSize(): Int = magic.size + Int.SIZE_BYTES * 3 + SALT_BYTES + NONCE_BYTES + TAG_BYTES
}
