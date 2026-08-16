package io.github.lamppkk.xanhbrowser.lite

import java.net.URLEncoder
import java.net.URI
import java.nio.charset.StandardCharsets

internal object AddressResolver {
    private const val SEARCH_URL = "https://duckduckgo.com/?q=%s&t=xanhbrowser"
    private val externalSchemes = setOf("mailto", "tel", "geo", "market")
    private val schemePattern = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")

    fun resolve(input: String): String {
        val value = input.trim()
        if (value.isEmpty()) return "about:blank"
        if (value.equals("localhost", ignoreCase = true) || value.startsWith("localhost:")) {
            return "http://$value"
        }

        val scheme = schemePattern.find(value)?.groupValues?.get(1)?.lowercase()
        when (scheme) {
            "http", "https" -> return if (isValidWebUrl(value)) value else search(value)
            in externalSchemes -> return value
            null -> Unit
            else -> return search(value)
        }

        if (!value.contains(' ') && (value.contains('.') || value.startsWith("["))) {
            val candidate = "https://$value"
            if (isValidWebUrl(candidate)) return candidate
        }
        return search(value)
    }

    fun isExternal(value: String): Boolean =
        schemePattern.find(value.trim())?.groupValues?.get(1)?.lowercase() in externalSchemes

    fun resolveWebIntent(value: String?): String? = value?.takeIf(::isValidWebUrl)

    fun isValidWebUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrBlank()
    }.getOrDefault(false)

    private fun search(value: String): String = SEARCH_URL.format(
        URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20"),
    )
}
