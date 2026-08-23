package io.github.lamppkk.xanhbrowser.lite

import android.Manifest
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.KeyEvent
import android.view.Menu
import android.view.MenuItem
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.text.InputType
import android.widget.EditText
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewDatabase
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AlertDialog
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.net.toUri
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.annotation.VisibleForTesting
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import io.github.lamppkk.xanhbrowser.lite.databinding.ActivityBrowserBinding
import io.github.lamppkk.xanhbrowser.backup.PortableBackup
import io.github.lamppkk.xanhbrowser.backup.PortableBackupPayload
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class BrowserActivity : AppCompatActivity() {
    private lateinit var binding: ActivityBrowserBinding
    private val preferences by lazy { getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE) }
    private var mobileUserAgent = ""
    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private var geolocationRequest: Pair<String, GeolocationPermissions.Callback>? = null
    private var geolocationDialog: AlertDialog? = null
    private var desktopSite = false
    private var currentNavigationUrl: String? = null
    private var pendingNavigationUrl: String? = null
    private var pendingBackupPassword: CharArray? = null
    private var webView: WebView? = null
    private var rendererGone = false
    private var rendererRecoveryUsed = false
    private var rendererRecoveryScheduled = false
    private var rendererRecoveryLoadPending = false
    private val syncFeature by lazy { SyncFeatureInstaller(this) }

    private val createBackupDocument = registerForActivityResult(
        ActivityResultContracts.CreateDocument(PortableBackup.MIME_TYPE),
    ) { uri ->
        val password = pendingBackupPassword
        pendingBackupPassword = null
        if (uri == null || password == null) {
            password?.fill('\u0000')
        } else {
            exportBackup(uri, password)
        }
    }

    private val openBackupDocument = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) promptBackupPassword(R.string.import_backup) { importBackup(uri, it) }
    }

    private val filePicker = registerForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        fileCallback?.onReceiveValue(uris.toTypedArray())
        fileCallback = null
    }

    private val locationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) confirmGeolocation() else completeGeolocation(false)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivityBrowserBinding.inflate(layoutInflater)
        setContentView(binding.root)
        rendererRecoveryUsed = savedInstanceState?.getBoolean(STATE_RENDERER_RECOVERY_USED) ?: false
        setSupportActionBar(binding.toolbar)
        applyInsets()
        configureWebView()
        configureAddressBar()
        configureBackNavigation()

        desktopSite = savedInstanceState?.getBoolean(STATE_DESKTOP_SITE) ?: false
        if (desktopSite) requestDesktopSite(true, reload = false)
        val savedUrl = savedInstanceState?.getString(STATE_CURRENT_URL)
        val recoveringRenderer = savedInstanceState?.getBoolean(STATE_RECREATE_AFTER_RENDERER) ?: false
        if (recoveringRenderer) {
            val target = RendererRecoveryPolicy.selectUrl(savedUrl, getString(R.string.app_website))
                ?: getString(R.string.app_website)
            pendingNavigationUrl = target
            currentNavigationUrl = target
            rendererRecoveryLoadPending = true
        } else {
            val restoredUrl = RendererRecoveryPolicy.selectUrl(
                savedUrl,
                AddressResolver.resolveWebIntent(intent.dataString),
                preferences.getString(LAST_URL, null),
            )
                ?: getString(R.string.app_website)
            loadUrlOrSearch(restoredUrl.orEmpty())
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        AddressResolver.resolveWebIntent(intent.dataString)?.let { url ->
            if (rendererGone || rendererRecoveryLoadPending) {
                pendingNavigationUrl = url
                currentNavigationUrl = url
            } else {
                loadUrlOrSearch(url)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (rendererRecoveryLoadPending) {
            rendererRecoveryLoadPending = false
            if (rendererRecoveryUsed) {
                Toast.makeText(this, R.string.renderer_recovery_stopped, Toast.LENGTH_LONG).show()
                finish()
                return
            }
            rendererRecoveryUsed = true
            val target = RendererRecoveryPolicy.selectUrl(
                pendingNavigationUrl,
                currentNavigationUrl,
                getString(R.string.app_website),
            ) ?: getString(R.string.app_website)
            loadUrlOrSearch(target)
            webView?.let(syncFeature::attachCredentialBridge)
            return
        }
        if (rendererGone) {
            scheduleRendererRecovery()
            return
        }
        webView?.let(syncFeature::attachCredentialBridge)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        val liveWebViewUrl = if (rendererGone) null else webView?.url
        outState.putString(
            STATE_CURRENT_URL,
            RendererRecoveryPolicy.selectUrl(
                pendingNavigationUrl,
                currentNavigationUrl,
                liveWebViewUrl,
            ),
        )
        outState.putBoolean(STATE_DESKTOP_SITE, desktopSite)
        outState.putBoolean(STATE_RENDERER_RECOVERY_USED, rendererRecoveryUsed)
        outState.putBoolean(
            STATE_RECREATE_AFTER_RENDERER,
            rendererGone || rendererRecoveryLoadPending,
        )
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        pendingBackupPassword?.fill('\u0000')
        pendingBackupPassword = null
        fileCallback?.onReceiveValue(null)
        fileCallback = null
        geolocationDialog?.setOnCancelListener(null)
        geolocationDialog?.dismiss()
        geolocationDialog = null
        completeGeolocation(false)
        syncFeature.destroy()
        webView?.let { current ->
            webView = null
            binding.webContainer.removeView(current)
            current.apply {
                stopLoading()
                webChromeClient = null
                destroy()
            }
        }
        super.onDestroy()
    }

    private fun applyInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
    }

    private fun configureWebView() {
        check(webView == null)
        val current = WebView(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        webView = current
        binding.webContainer.addView(current)
        with(current) {
            WebView.setWebContentsDebuggingEnabled(false)
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                allowFileAccess = false
                allowContentAccess = true
                mediaPlaybackRequiresUserGesture = true
                setSupportMultipleWindows(false)
                safeBrowsingEnabled = true
            }
            CookieManager.getInstance().apply {
                setAcceptCookie(true)
                setAcceptThirdPartyCookies(current, false)
            }
            mobileUserAgent = settings.userAgentString
            settings.userAgentString = "$mobileUserAgent XanhBrowser/1.0"
            webViewClient = XanhWebViewClient(this@BrowserActivity)
            webChromeClient = XanhWebChromeClient(this@BrowserActivity)
            setDownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
                enqueueDownload(url, userAgent, contentDisposition, mimeType)
            }
        }
    }

    internal fun onRendererGone(view: WebView): Boolean {
        if (rendererGone || webView !== view) return true
        rendererGone = true
        syncFeature.abandonRenderer()
        fileCallback?.onReceiveValue(null)
        fileCallback = null
        cancelGeolocation()
        webView = null
        (view.parent as? ViewGroup)?.removeView(view)
        view.destroy()
        scheduleRendererRecovery()
        return true
    }

    private fun scheduleRendererRecovery() {
        if (isFinishing || isDestroyed) return
        if (rendererRecoveryScheduled) return
        if (rendererRecoveryUsed) {
            Toast.makeText(this, R.string.renderer_recovery_stopped, Toast.LENGTH_LONG).show()
            finish()
            return
        }
        if (!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        rendererRecoveryScheduled = true
        binding.root.post {
            rendererRecoveryScheduled = false
            if (
                !isFinishing &&
                !isDestroyed &&
                rendererGone &&
                lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            ) {
                recreate()
            }
        }
    }

    private fun configureAddressBar() {
        binding.urlBar.setOnEditorActionListener { view, actionId, event ->
            val submitted = actionId == EditorInfo.IME_ACTION_GO ||
                (event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
            if (submitted) {
                hideKeyboard(view.windowToken)
                loadUrlOrSearch(view.text.toString())
            }
            submitted
        }
    }

    private fun configureBackNavigation() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val current = webView
                if (current?.canGoBack() == true) current.goBack() else finish()
            }
        })
    }

    private fun hideKeyboard(windowToken: android.os.IBinder) {
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
            .hideSoftInputFromWindow(windowToken, 0)
    }

    private fun loadUrlOrSearch(input: String) {
        val resolved = AddressResolver.resolve(input)
        val uri = resolved.toUri()
        if (AddressResolver.isExternal(resolved)) {
            openExternal(uri)
        } else {
            pendingNavigationUrl = resolved
            currentNavigationUrl = resolved
            webView?.loadUrl(resolved)
        }
    }

    internal fun onPageStarted(url: String?) {
        if (rendererGone) return
        syncFeature.navigationStarted(url)
        if (!url.isNullOrBlank() && url != "about:blank") {
            currentNavigationUrl = url
            pendingNavigationUrl = null
        }
        onProgress(0)
    }

    internal fun onPageChanged(url: String?, title: String?) {
        if (rendererGone) return
        syncFeature.navigationCommitted(url, title)
        if (
            !url.isNullOrBlank() &&
            url != "about:blank" &&
            (pendingNavigationUrl == null || pendingNavigationUrl == url) &&
            (pendingNavigationUrl != null || currentNavigationUrl == null || currentNavigationUrl == url)
        ) {
            currentNavigationUrl = url
            pendingNavigationUrl = null
            binding.urlBar.setText(url)
            RendererRecoveryPolicy.selectUrl(url)?.let { safeUrl ->
                preferences.edit { putString(LAST_URL, safeUrl) }
            }
            supportActionBar?.subtitle = title
        }
    }

    internal fun onProgress(progress: Int) {
        if (rendererGone) return
        binding.loadingProgress.progress = progress
        binding.loadingProgress.visibility = if (progress in 0..99) android.view.View.VISIBLE else android.view.View.GONE
    }

    @VisibleForTesting
    internal fun loadWebUrlForTest(url: String) = loadUrlOrSearch(url)

    @VisibleForTesting
    internal fun currentWebUrlForTest(): String? = webView?.url

    @VisibleForTesting
    internal fun currentWebViewIdentityForTest(): Int? =
        webView?.let(System::identityHashCode)

    @VisibleForTesting
    internal fun rendererRecoveryUsedForTest(): Boolean = rendererRecoveryUsed

    @VisibleForTesting
    internal fun terminateCurrentRendererForTest(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return webView?.webViewRenderProcess?.terminate() == true
    }

    internal fun openExternal(uri: Uri): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        if (intent.resolveActivity(packageManager) == null) {
            Toast.makeText(this, R.string.no_app_for_link, Toast.LENGTH_SHORT).show()
            return false
        }
        return runCatching { startActivity(intent) }
            .onFailure { Toast.makeText(this, R.string.no_app_for_link, Toast.LENGTH_SHORT).show() }
            .isSuccess
    }

    internal fun chooseFiles(
        callback: ValueCallback<Array<Uri>>,
        acceptTypes: Array<String>,
    ): Boolean {
        if (rendererGone || webView == null) {
            callback.onReceiveValue(null)
            return false
        }
        fileCallback?.onReceiveValue(null)
        fileCallback = callback
        val types = acceptTypes.filter { it.isNotBlank() }.ifEmpty { listOf("*/*") }.toTypedArray()
        return runCatching {
            filePicker.launch(types)
            true
        }.getOrElse {
            fileCallback?.onReceiveValue(null)
            fileCallback = null
            false
        }
    }

    internal fun requestGeolocation(origin: String, callback: GeolocationPermissions.Callback) {
        if (rendererGone || webView == null) {
            callback.invoke(origin, false, false)
            return
        }
        geolocationDialog?.setOnCancelListener(null)
        geolocationDialog?.dismiss()
        geolocationDialog = null
        completeGeolocation(false)
        geolocationRequest = origin to callback
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            confirmGeolocation()
            return
        }
        locationPermission.launch(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    internal fun cancelGeolocation() {
        geolocationDialog?.setOnCancelListener(null)
        geolocationDialog?.dismiss()
        geolocationDialog = null
        completeGeolocation(false)
    }

    private fun confirmGeolocation() {
        val (origin, _) = geolocationRequest ?: return
        geolocationDialog = AlertDialog.Builder(this)
            .setTitle(R.string.location_request_title)
            .setMessage(getString(R.string.location_request_message, origin))
            .setNegativeButton(R.string.deny) { _, _ -> completeGeolocation(false) }
            .setPositiveButton(R.string.allow_once) { _, _ -> completeGeolocation(true) }
            .setOnCancelListener { completeGeolocation(false) }
            .show()
    }

    private fun completeGeolocation(allowed: Boolean) {
        geolocationRequest?.let { (origin, callback) -> callback.invoke(origin, allowed, false) }
        geolocationRequest = null
        geolocationDialog = null
    }

    private fun enqueueDownload(
        url: String,
        userAgent: String?,
        contentDisposition: String?,
        mimeType: String?,
    ) {
        runCatching {
            val uri = url.toUri()
            require(uri.scheme == "https" || uri.scheme == "http")
            val fileName = URLUtil.guessFileName(url, contentDisposition, mimeType)
            val request = DownloadManager.Request(uri)
                .setTitle(fileName)
                .setDescription(getString(R.string.download_started))
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName)
            } else {
                request.setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, fileName)
            }
            userAgent?.let { request.addRequestHeader("User-Agent", it) }
            CookieManager.getInstance().getCookie(url)?.let { request.addRequestHeader("Cookie", it) }
            mimeType?.let(request::setMimeType)
            (getSystemService(DOWNLOAD_SERVICE) as DownloadManager).enqueue(request)
            Toast.makeText(this, R.string.download_started, Toast.LENGTH_SHORT).show()
        }.onFailure {
            Toast.makeText(this, R.string.download_failed, Toast.LENGTH_SHORT).show()
        }
    }

    private fun requestDesktopSite(enabled: Boolean, reload: Boolean = true) {
        val current = webView ?: return
        with(current.settings) {
            desktopSite = enabled
            userAgentString = if (enabled) {
                mobileUserAgent.replace("; wv", "").replace(" Mobile", "") + " XanhBrowser/1.0"
            } else {
                "$mobileUserAgent XanhBrowser/1.0"
            }
            useWideViewPort = enabled
            loadWithOverviewMode = enabled
            if (reload) current.reload()
        }
    }

    private fun clearPrivateData() {
        WebStorage.getInstance().deleteAllData()
        clearLegacyWebViewCredentials()
        webView?.apply {
            clearCache(true)
            clearHistory()
            clearFormData()
            clearSslPreferences()
        }
        preferences.edit { remove(LAST_URL) }
        var pendingOperations = 2
        fun finishOperation() {
            pendingOperations--
            if (pendingOperations == 0) {
                Toast.makeText(this, R.string.private_data_cleared, Toast.LENGTH_SHORT).show()
            }
        }
        CookieManager.getInstance().removeAllCookies {
            CookieManager.getInstance().flush()
            runOnUiThread(::finishOperation)
        }
        WebView.clearClientCertPreferences { runOnUiThread(::finishOperation) }
    }

    @Suppress("DEPRECATION")
    private fun clearLegacyWebViewCredentials() {
        WebViewDatabase.getInstance(this).apply {
            clearFormData()
            clearHttpAuthUsernamePassword()
            clearUsernamePassword()
        }
    }

    private fun sharePage() {
        val current = webView ?: return
        val url = current.url ?: return
        val share = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, url)
            putExtra(Intent.EXTRA_TITLE, current.title)
        }
        startActivity(Intent.createChooser(share, getString(R.string.share)))
    }

    private fun openDownloads() {
        val downloads = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
        if (downloads.resolveActivity(packageManager) != null) startActivity(downloads)
        else Toast.makeText(this, R.string.no_app_for_link, Toast.LENGTH_SHORT).show()
    }

    private fun chooseBackupDestination() {
        promptBackupPassword(R.string.export_backup) { password ->
            pendingBackupPassword?.fill('\u0000')
            pendingBackupPassword = password
            createBackupDocument.launch("xanh-browser-lite-${System.currentTimeMillis()}${PortableBackup.FILE_EXTENSION}")
        }
    }

    private fun chooseBackupToImport() {
        openBackupDocument.launch(arrayOf(PortableBackup.MIME_TYPE, "application/octet-stream"))
    }

    private fun promptBackupPassword(title: Int, onAccepted: (CharArray) -> Unit) {
        val input = EditText(this).apply {
            hint = getString(R.string.backup_password_hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(R.string.backup_password_description)
            .setView(input)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val password = input.text.toString().toCharArray()
                if (password.size < 8) {
                    password.fill('\u0000')
                    Toast.makeText(this, R.string.backup_password_too_short, Toast.LENGTH_SHORT).show()
                } else {
                    onAccepted(password)
                }
                input.text?.clear()
            }
            .show()
    }

    private fun exportBackup(uri: Uri, password: CharArray) {
        val candidate = pendingNavigationUrl ?: currentNavigationUrl ?: webView?.url
        val url = candidate?.takeIf(PortableBackup::isSupportedWebUrl)
            ?: getString(R.string.app_website)
        val payload = PortableBackupPayload(
            createdAtEpochMillis = System.currentTimeMillis(),
            sourceEdition = "android-lite",
            urls = listOf(url),
            selectedIndex = 0,
            desktopSite = desktopSite,
        )
        lifecycleScope.launch {
            val result = try {
                withContext(Dispatchers.IO) {
                    runCatching {
                        val encoded = PortableBackup.encode(payload, password)
                        contentResolver.openOutputStream(uri, "w")?.use { it.write(encoded) }
                            ?: error("Cannot open backup destination")
                    }
                }
            } finally {
                password.fill('\u0000')
            }
            Toast.makeText(
                this@BrowserActivity,
                if (result.isSuccess) R.string.backup_exported else R.string.backup_failed,
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    private fun importBackup(uri: Uri, password: CharArray) {
        lifecycleScope.launch {
            val result = try {
                withContext(Dispatchers.IO) {
                    runCatching {
                        val encoded = contentResolver.openInputStream(uri)?.use(::readBoundedBackup)
                            ?: error("Cannot open backup")
                        PortableBackup.decode(encoded, password)
                    }
                }
            } finally {
                password.fill('\u0000')
            }
            result.onSuccess { backup ->
                desktopSite = backup.desktopSite
                requestDesktopSite(desktopSite, reload = false)
                loadUrlOrSearch(backup.urls[backup.selectedIndex])
                Toast.makeText(this@BrowserActivity, R.string.backup_imported, Toast.LENGTH_SHORT).show()
            }.onFailure {
                Toast.makeText(this@BrowserActivity, R.string.backup_failed, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun readBoundedBackup(input: java.io.InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= PortableBackup.MAX_ENCODED_BYTES) { "Backup is too large" }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.app_menu, menu)
        menu.findItem(R.id.action_firefox_sync)?.isVisible = BuildConfig.XANH_SYNC_FEATURE_ENABLED
        return true
    }

    override fun onPrepareOptionsMenu(menu: Menu): Boolean {
        menu.findItem(R.id.action_desktop_site)?.isChecked = desktopSite
        return super.onPrepareOptionsMenu(menu)
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        R.id.action_back -> {
            webView?.let { if (it.canGoBack()) it.goBack() }
            true
        }
        R.id.action_forward -> {
            webView?.let { if (it.canGoForward()) it.goForward() }
            true
        }
        R.id.action_reload -> {
            webView?.reload()
            true
        }
        R.id.action_share -> {
            sharePage()
            true
        }
        R.id.action_desktop_site -> {
            requestDesktopSite(!desktopSite)
            item.isChecked = desktopSite
            true
        }
        R.id.action_downloads -> {
            openDownloads()
            true
        }
        R.id.action_export_backup -> {
            chooseBackupDestination()
            true
        }
        R.id.action_import_backup -> {
            chooseBackupToImport()
            true
        }
        R.id.action_firefox_sync -> {
            syncFeature.open(webView?.url, webView?.title)
            true
        }
        R.id.action_clear_private_data -> {
            clearPrivateData()
            true
        }
        R.id.action_app_settings -> {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:$packageName".toUri()))
            true
        }
        else -> super.onOptionsItemSelected(item)
    }

    companion object {
        private const val PREFERENCES = "xanh_browser_lite"
        private const val LAST_URL = "last_url"
        private const val STATE_CURRENT_URL = "state_current_url"
        private const val STATE_DESKTOP_SITE = "state_desktop_site"
        private const val STATE_RENDERER_RECOVERY_USED = "state_renderer_recovery_used"
        private const val STATE_RECREATE_AFTER_RENDERER = "state_recreate_after_renderer"
    }
}
