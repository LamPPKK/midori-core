package io.github.lamppkk.xanhbrowser.lite.webkit

import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

internal object WebKitAddressResolver {
    const val HOME_URL = "https://duckduckgo.com/"
    private const val SEARCH_URL = "https://duckduckgo.com/?q=%s&t=xanhbrowser-webkit"
    private const val MAX_URL_LENGTH = 8_192
    private val externalSchemes = setOf("mailto", "tel", "geo", "market")
    private val schemePattern = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")

    fun resolve(input: String): String {
        val value = input.trim()
        if (value.isEmpty()) return HOME_URL
        if (!isWithinUrlLimit(value)) return HOME_URL

        val scheme = schemePattern.find(value)?.groupValues?.get(1)?.lowercase()
        when (scheme) {
            "http", "https" -> return if (isValidWebUrl(value)) value else search(value)
            in externalSchemes -> return if (isExternal(value)) value else search(value)
            null -> Unit
            else -> return search(value)
        }

        if (!value.contains(' ') && (value.contains('.') || value.startsWith("["))) {
            val candidate = "https://$value"
            if (isValidWebUrl(candidate)) return candidate
        }
        return search(value)
    }

    fun isExternal(value: String): Boolean = runCatching {
        val normalized = value.trim()
        if (normalized.isEmpty() || !isWithinUrlLimit(normalized) || normalized.any(Char::isISOControl)) {
            return@runCatching false
        }
        val uri = URI(normalized)
        uri.scheme?.lowercase() in externalSchemes && !uri.rawSchemeSpecificPart.isNullOrBlank()
    }.getOrDefault(false)

    fun resolveWebIntent(value: String?): String? = value?.takeIf(::isValidWebUrl)

    fun isValidWebUrl(value: String): Boolean = runCatching {
        if (!isWithinUrlLimit(value) || value.any(Char::isISOControl)) return@runCatching false
        val uri = URI(value)
        uri.scheme?.lowercase() in setOf("http", "https") &&
            !uri.host.isNullOrBlank() &&
            uri.rawUserInfo == null &&
            uri.port in -1..65_535
    }.getOrDefault(false)

    private fun search(value: String): String {
        val candidate = SEARCH_URL.format(
            URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20"),
        )
        return candidate.takeIf(::isWithinUrlLimit) ?: HOME_URL
    }

    private fun isWithinUrlLimit(value: String): Boolean =
        value.length <= MAX_URL_LENGTH && value.toByteArray(StandardCharsets.UTF_8).size <= MAX_URL_LENGTH
}
