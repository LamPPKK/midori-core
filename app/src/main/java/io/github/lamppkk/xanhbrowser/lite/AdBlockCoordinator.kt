package io.github.lamppkk.xanhbrowser.lite

import android.content.Context
import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import androidx.core.content.edit
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.IDN
import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.Locale

/** Request shape shared by the Kotlin host and the packaged adblock-rust C ABI. */
internal data class AdBlockMatchRequest(
    val targetUrl: String,
    val sourceUrl: String,
    val targetHost: String,
    val sourceHost: String,
    val resourceType: AdBlockResourceType,
    val method: String,
)

internal enum class AdBlockResourceType(val engineValue: String) {
    FONT("font"),
    IMAGE("image"),
    MEDIA("media"),
    OBJECT("object"),
    OTHER("other"),
    SCRIPT("script"),
    STYLESHEET("stylesheet"),
    SUBDOCUMENT("subdocument"),
    XMLHTTPREQUEST("xmlhttprequest"),
}

/** Injectable boundary implemented by both the bounded fallback and the JNA native adapter. */
internal fun interface AdBlockMatcher {
    fun shouldBlock(request: AdBlockMatchRequest): Boolean
}

/** JNA bridge to the stable C ABI exported by the sibling `xanh-adblock-core` crate. */
internal class NativeAdBlockMatcher private constructor(
    private val api: Api,
    private val engine: Pointer,
) : AdBlockMatcher {
    override fun shouldBlock(request: AdBlockMatchRequest): Boolean {
        val decision = api.xanh_adblock_engine_should_block(
            engine,
            request.targetUrl,
            request.sourceUrl,
            request.resourceType.engineValue,
            request.method,
        )
        if (decision < 0) throw IllegalStateException("native adblock matcher rejected the request")
        return decision == 1
    }

    /**
     * The engine deliberately lives for the application process. WebView can call the matcher
     * concurrently, so freeing it during Activity teardown would race worker threads.
     */
    private interface Api : Library {
        fun xanh_adblock_core_version(): Pointer?
        fun xanh_adblock_engine_create_default(): Pointer?
        fun xanh_adblock_engine_should_block(
            engine: Pointer,
            url: String,
            sourceUrl: String,
            requestType: String,
            method: String,
        ): Int
    }

    companion object {
        const val EXPECTED_VERSION = "1.0.0-alpha.1"
        private const val LIBRARY_NAME = "xanh_adblock_core"

        fun tryCreate(): NativeAdBlockMatcher? {
            return try {
                val api = Native.load(
                    LIBRARY_NAME,
                    Api::class.java,
                    mapOf(Library.OPTION_STRING_ENCODING to StandardCharsets.UTF_8.name()),
                )
                val version = api.xanh_adblock_core_version() ?: return null
                if (!hasExactVersion(version)) return null
                val engine = api.xanh_adblock_engine_create_default() ?: return null
                NativeAdBlockMatcher(api, engine)
            } catch (error: Throwable) {
                error.rethrowIfFatal()
                null
            }
        }

        internal fun hasExactVersion(pointer: Pointer): Boolean {
            val expected = EXPECTED_VERSION.toByteArray(StandardCharsets.UTF_8)
            val bytes = ByteArray(expected.size + 1) { pointer.getByte(it.toLong()) }
            return acceptsVersionBytes(bytes)
        }

        internal fun acceptsVersionBytes(value: ByteArray): Boolean {
            val expected = EXPECTED_VERSION.toByteArray(StandardCharsets.UTF_8)
            return value.size == expected.size + 1 &&
                expected.indices.all { value[it] == expected[it] } &&
                value.last().toInt() == 0
        }
    }
}

/** Pure request validation and classification, kept independent from Android for unit tests. */
internal object AdBlockRequestPolicy {
    internal const val MAX_URL_BYTES = 8_192
    private const val MAX_HEADER_VALUE_CHARS = 512
    private const val MAX_METHOD_CHARS = 16
    private val HOST_PATTERN = Regex(
        "^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)*" +
            "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
    )

    fun exceedsNativeUrlLimit(value: String): Boolean =
        value.length > MAX_URL_BYTES ||
            value.toByteArray(StandardCharsets.UTF_8).size > MAX_URL_BYTES

    fun normalizeFallbackHost(value: String?): String? = runCatching {
        val ascii = IDN.toASCII(value?.trimEnd('.') ?: return null, IDN.USE_STD3_ASCII_RULES)
            .lowercase(Locale.ROOT)
        ascii.takeIf(HOST_PATTERN::matches)
    }.getOrNull()

    fun sourceHostForFallback(value: String?): String? {
        if (value == null || exceedsNativeUrlLimit(value)) return null
        return parseBoundedWebUrl(value)?.host
    }

    fun create(
        targetUrl: String,
        sourceUrl: String?,
        isForMainFrame: Boolean,
        method: String,
        headers: Map<String, String>,
    ): AdBlockMatchRequest? {
        // Content blocking must never turn a typed or clicked top-level navigation into a blank page.
        if (isForMainFrame) return null
        val target = parseBoundedWebUrl(targetUrl) ?: return null
        val safeMethod = method
            .takeIf { it.length in 1..MAX_METHOD_CHARS && it.all(Char::isLetter) }
            ?.lowercase(Locale.ROOT)
            ?: return null
        // Unknown sources are conservatively first-party so incomplete WebView metadata cannot
        // over-block traffic. The native ABI also requires a non-empty source URL.
        val safeSource = sourceUrl?.let(::parseBoundedWebUrl) ?: target
        return AdBlockMatchRequest(
            targetUrl = target.text,
            sourceUrl = safeSource.text,
            targetHost = target.host,
            sourceHost = safeSource.host,
            resourceType = inferResourceType(headers, target.path),
            method = safeMethod,
        )
    }

    private fun parseBoundedWebUrl(value: String): ParsedWebUrl? {
        if (value.isEmpty() || value.length > MAX_URL_BYTES || value.any(Char::isISOControl)) return null
        if (value.toByteArray(StandardCharsets.UTF_8).size > MAX_URL_BYTES) return null
        return runCatching {
            val uri = URI(value)
            require(uri.scheme.equals("http", true) || uri.scheme.equals("https", true))
            require(!uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.port in -1..65_535)
            ParsedWebUrl(
                text = value,
                host = uri.host.lowercase(Locale.ROOT).trimEnd('.'),
                path = uri.rawPath.orEmpty().lowercase(Locale.ROOT),
            )
        }.getOrNull()
    }

    private fun inferResourceType(headers: Map<String, String>, path: String): AdBlockResourceType {
        when (header(headers, "Sec-Fetch-Dest")?.lowercase(Locale.ROOT)) {
            "audio", "track", "video" -> return AdBlockResourceType.MEDIA
            "embed", "object" -> return AdBlockResourceType.OBJECT
            "font" -> return AdBlockResourceType.FONT
            "frame", "iframe" -> return AdBlockResourceType.SUBDOCUMENT
            "image" -> return AdBlockResourceType.IMAGE
            "script", "serviceworker", "sharedworker", "worker" -> {
                return AdBlockResourceType.SCRIPT
            }
            "style" -> return AdBlockResourceType.STYLESHEET
            "empty" -> return AdBlockResourceType.XMLHTTPREQUEST
        }

        val accept = header(headers, "Accept")?.lowercase(Locale.ROOT).orEmpty()
        when {
            "text/css" in accept -> return AdBlockResourceType.STYLESHEET
            "javascript" in accept || "ecmascript" in accept -> return AdBlockResourceType.SCRIPT
            "image/" in accept -> return AdBlockResourceType.IMAGE
            "font/" in accept || "application/font" in accept -> return AdBlockResourceType.FONT
            "audio/" in accept || "video/" in accept -> return AdBlockResourceType.MEDIA
            "text/html" in accept || "application/xhtml+xml" in accept -> {
                return AdBlockResourceType.SUBDOCUMENT
            }
        }

        return when (path.substringAfterLast('.', missingDelimiterValue = "")) {
            "css" -> AdBlockResourceType.STYLESHEET
            "js", "mjs" -> AdBlockResourceType.SCRIPT
            "avif", "bmp", "gif", "ico", "jpeg", "jpg", "png", "svg", "webp" -> {
                AdBlockResourceType.IMAGE
            }
            "eot", "otf", "ttf", "woff", "woff2" -> AdBlockResourceType.FONT
            "aac", "m4a", "m4v", "mp3", "mp4", "ogg", "ogv", "webm", "wav" -> {
                AdBlockResourceType.MEDIA
            }
            else -> AdBlockResourceType.OTHER
        }
    }

    private fun header(headers: Map<String, String>, name: String): String? =
        headers.entries
            .firstOrNull { it.key.equals(name, ignoreCase = true) }
            ?.value
            ?.takeIf { it.length <= MAX_HEADER_VALUE_CHARS }

    private data class ParsedWebUrl(val text: String, val host: String, val path: String)
}

/** Executes matcher calls without letting an unavailable or failing native adapter block traffic. */
internal class AdBlockHost(
    private val enabled: () -> Boolean,
    private val fallbackMatcher: AdBlockMatcher,
    matcher: AdBlockMatcher = fallbackMatcher,
) {
    @Volatile
    private var activeMatcher = matcher

    fun replaceMatcher(matcher: AdBlockMatcher) {
        activeMatcher = matcher
    }

    fun shouldBlock(
        targetUrl: String,
        sourceUrl: String?,
        isForMainFrame: Boolean,
        method: String,
        headers: Map<String, String>,
    ): Boolean {
        return try {
            if (!enabled()) return false
            val request = AdBlockRequestPolicy.create(
                targetUrl = targetUrl,
                sourceUrl = sourceUrl,
                isForMainFrame = isForMainFrame,
                method = method,
                headers = headers,
            ) ?: return false
            val matcher = activeMatcher
            try {
                matcher.shouldBlock(request)
            } catch (error: Throwable) {
                error.rethrowIfFatal()
                if (matcher !== fallbackMatcher) fallbackMatcher.shouldBlock(request) else false
            }
        } catch (error: Throwable) {
            error.rethrowIfFatal()
            false
        }
    }
}

/** Process-wide Android content-blocking host for the System WebView Lite app. */
internal class AdBlockCoordinator private constructor(context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val fallbackMatcher = BundledAbpDomainMatcher.load(context)
    private val host = AdBlockHost(::isEnabled, fallbackMatcher)

    @Suppress("unused") // Retains the JNA proxy and process-lifetime native engine.
    private val nativeMatcher = NativeAdBlockMatcher.tryCreate()?.also(host::replaceMatcher)

    private val serviceWorkerClient = object : ServiceWorkerClient() {
        override fun shouldInterceptRequest(request: WebResourceRequest): WebResourceResponse? =
            shouldIntercept(request, null)
    }

    fun isEnabled(): Boolean = preferences.getBoolean(ENABLED, DEFAULT_ENABLED)

    fun setEnabled(enabled: Boolean) {
        preferences.edit { putBoolean(ENABLED, enabled) }
    }

    /**
     * Installs a process-lifetime matcher safe for concurrent calls. Native owners must keep old
     * engines alive until process shutdown so in-flight WebView worker calls cannot race a free.
     */
    fun installMatcher(matcher: AdBlockMatcher?) {
        host.replaceMatcher(matcher ?: fallbackMatcher)
    }

    fun installDefaultServiceWorkerClient() {
        runCatching {
            ServiceWorkerController.getInstance().setServiceWorkerClient(serviceWorkerClient)
        }
    }

    fun shouldIntercept(request: WebResourceRequest, sourceUrl: String?): WebResourceResponse? {
        if (request.isForMainFrame) return null
        if (
            !request.url.scheme.equals("http", ignoreCase = true) &&
            !request.url.scheme.equals("https", ignoreCase = true)
        ) return null
        val targetUrl = request.url.toString()
        val blocked = try {
            if (AdBlockRequestPolicy.exceedsNativeUrlLimit(targetUrl)) {
                val targetHost = AdBlockRequestPolicy.normalizeFallbackHost(request.url.host)
                    ?: return null
                val sourceHost = AdBlockRequestPolicy.sourceHostForFallback(sourceUrl) ?: targetHost
                isEnabled() && fallbackMatcher.shouldBlockHosts(targetHost, sourceHost)
            } else {
                host.shouldBlock(
                    targetUrl = targetUrl,
                    sourceUrl = sourceUrl,
                    isForMainFrame = false,
                    method = request.method,
                    headers = request.requestHeaders,
                )
            }
        } catch (error: Throwable) {
            error.rethrowIfFatal()
            false
        }
        return if (blocked) emptyBlockedResponse() else null
    }

    private fun emptyBlockedResponse(): WebResourceResponse = WebResourceResponse(
        "text/plain",
        "utf-8",
        204,
        "No Content",
        mapOf(
            "Cache-Control" to "no-store",
            "Content-Length" to "0",
        ),
        ByteArrayInputStream(EMPTY_BODY),
    )

    companion object {
        internal const val DEFAULT_ENABLED = true
        private const val PREFERENCES = "xanh_content_blocking"
        private const val ENABLED = "enabled"
        private val EMPTY_BODY = ByteArray(0)

        @Volatile
        private var instance: AdBlockCoordinator? = null

        fun get(context: Context): AdBlockCoordinator = instance ?: synchronized(this) {
            instance ?: AdBlockCoordinator(context.applicationContext).also { instance = it }
        }
    }
}

/** Small, audited bootstrap matcher used while the native engine is unavailable or rejects input. */
internal class BundledAbpDomainMatcher private constructor(
    private val blockedDomains: Set<String>,
    private val allowedDomains: Set<String>,
    private val thirdPartyBlockedDomains: Set<String>,
    private val thirdPartyAllowedDomains: Set<String>,
) : AdBlockMatcher {
    override fun shouldBlock(request: AdBlockMatchRequest): Boolean =
        shouldBlockHosts(request.targetHost, request.sourceHost)

    fun shouldBlockHosts(targetHost: String, sourceHost: String): Boolean {
        if (matchesDomain(targetHost, allowedDomains)) return false
        val thirdParty = isThirdParty(targetHost, sourceHost)
        if (thirdParty && matchesDomain(targetHost, thirdPartyAllowedDomains)) return false
        return matchesDomain(targetHost, blockedDomains) ||
            (thirdParty && matchesDomain(targetHost, thirdPartyBlockedDomains))
    }

    private fun matchesDomain(host: String, domains: Set<String>): Boolean {
        var candidate = host
        while (candidate.isNotEmpty()) {
            if (candidate in domains) return true
            val separator = candidate.indexOf('.')
            if (separator < 0) return false
            candidate = candidate.substring(separator + 1)
        }
        return false
    }

    private fun isThirdParty(targetHost: String, sourceHost: String): Boolean =
        approximateSite(targetHost) != approximateSite(sourceHost)

    private fun approximateSite(host: String): String {
        val lastSeparator = host.lastIndexOf('.')
        if (lastSeparator <= 0) return host
        val previousSeparator = host.lastIndexOf('.', lastSeparator - 1)
        return if (previousSeparator < 0) host else host.substring(previousSeparator + 1)
    }

    companion object {
        private const val ASSET_PATH = "adblock/fallback-domain-rules.txt"
        private const val MAX_RULE_BYTES = 32 * 1024
        private const val MAX_RULES = 256
        private val DOMAIN_PATTERN = Regex(
            "^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)*" +
                "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
        )

        private val DEFAULT_RULES = """
            ||doubleclick.net^
            ||googlesyndication.com^
            ||google-analytics.com^
            ||adservice.google.com^
            ||amazon-adsystem.com^
            ||scorecardresearch.com^
            ||connect.facebook.net^${'$'}third-party
        """.trimIndent()

        fun load(context: Context): BundledAbpDomainMatcher = try {
            context.assets.open(ASSET_PATH).use { stream ->
                parse(readBounded(stream).toString(StandardCharsets.UTF_8))
                    ?: requireNotNull(parse(DEFAULT_RULES))
            }
        } catch (error: Throwable) {
            error.rethrowIfFatal()
            requireNotNull(parse(DEFAULT_RULES))
        }

        internal fun fromText(text: String): BundledAbpDomainMatcher = parse(text) ?: empty()

        private fun parse(text: String): BundledAbpDomainMatcher? {
            if (
                text.length > MAX_RULE_BYTES ||
                text.toByteArray(StandardCharsets.UTF_8).size > MAX_RULE_BYTES
            ) return null

            val blocked = linkedSetOf<String>()
            val allowed = linkedSetOf<String>()
            val thirdPartyBlocked = linkedSetOf<String>()
            val thirdPartyAllowed = linkedSetOf<String>()
            var ruleCount = 0
            for (rawLine in text.lineSequence()) {
                val line = rawLine.trim()
                if (line.isEmpty() || line.startsWith('!')) continue
                val exception = line.startsWith("@@")
                val rule = if (exception) line.removePrefix("@@") else line
                val optionSeparator = rule.indexOf('$')
                val domainRule = if (optionSeparator >= 0) rule.substring(0, optionSeparator) else rule
                val options = if (optionSeparator >= 0) rule.substring(optionSeparator + 1) else null
                val thirdPartyOnly = when (options) {
                    null -> false
                    "third-party" -> true
                    else -> continue
                }
                if (!domainRule.startsWith("||") || !domainRule.endsWith('^')) continue
                val domain = domainRule
                    .removePrefix("||")
                    .removeSuffix("^")
                    .lowercase(Locale.ROOT)
                if (!DOMAIN_PATTERN.matches(domain)) continue
                ruleCount += 1
                if (ruleCount > MAX_RULES) return null
                when {
                    exception && thirdPartyOnly -> thirdPartyAllowed.add(domain)
                    exception -> allowed.add(domain)
                    thirdPartyOnly -> thirdPartyBlocked.add(domain)
                    else -> blocked.add(domain)
                }
            }
            if (blocked.isEmpty() && thirdPartyBlocked.isEmpty()) return null
            return BundledAbpDomainMatcher(
                blockedDomains = blocked,
                allowedDomains = allowed,
                thirdPartyBlockedDomains = thirdPartyBlocked,
                thirdPartyAllowedDomains = thirdPartyAllowed,
            )
        }

        private fun empty() = BundledAbpDomainMatcher(
            blockedDomains = emptySet(),
            allowedDomains = emptySet(),
            thirdPartyBlockedDomains = emptySet(),
            thirdPartyAllowedDomains = emptySet(),
        )

        private fun readBounded(stream: InputStream): ByteArray {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                require(output.size() + count <= MAX_RULE_BYTES)
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }
}

private fun Throwable.rethrowIfFatal() {
    if (this is ThreadDeath || this is VirtualMachineError) throw this
}
