package io.github.lamppkk.xanhbrowser.lite.webkit

internal enum class WebKitNavigationDecision {
    ALLOW,
    BLOCK,
    OPEN_EXTERNAL,
}

internal object WebKitNavigationPolicy {
    fun decide(url: String, isRedirect: Boolean, hasUserGesture: Boolean): WebKitNavigationDecision = when {
        url == "about:blank" -> WebKitNavigationDecision.ALLOW
        WebKitAddressResolver.isValidWebUrl(url) -> WebKitNavigationDecision.ALLOW
        WebKitAddressResolver.isExternal(url) && hasUserGesture && !isRedirect ->
            WebKitNavigationDecision.OPEN_EXTERNAL
        else -> WebKitNavigationDecision.BLOCK
    }
}
