package io.github.lamppkk.xanhbrowser.lite

/** Selects a bounded GET target without restoring renderer-owned state or request bodies. */
internal object RendererRecoveryPolicy {
    fun selectUrl(vararg candidates: String?): String? = candidates.firstNotNullOfOrNull { value ->
        value?.takeIf(AddressResolver::isValidWebUrl)
    }
}
