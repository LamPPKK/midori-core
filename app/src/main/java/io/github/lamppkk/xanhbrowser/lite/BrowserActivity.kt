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
        setSupportActionBar(binding.toolbar)
        applyInsets()
        configureWebView()
        configureAddressBar()
        configureBackNavigation()

        desktopSite = savedInstanceState?.getBoolean(STATE_DESKTOP_SITE) ?: false
        if (desktopSite) requestDesktopSite(true, reload = false)
        val savedUrl = savedInstanceState?.getString(STATE_CURRENT_URL)
        val restored = savedInstanceState?.getBundle(STATE_WEB_VIEW)?.let(binding.webView::restoreState)
        val restoredUrl = restored?.currentItem?.url
        if (savedUrl != null && savedUrl != restoredUrl) {
            loadUrlOrSearch(savedUrl)
        } else if (restored == null) {
            val restoredUrl = AddressResolver.resolveWebIntent(intent.dataString)
                ?: preferences.getString(LAST_URL, null)
                ?: getString(R.string.app_website)
            loadUrlOrSearch(restoredUrl.orEmpty())
        } else {
            currentNavigationUrl = restoredUrl
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        AddressResolver.resolveWebIntent(intent.dataString)?.let(::loadUrlOrSearch)
    }

    override fun onResume() {
        super.onResume()
        syncFeature.attachCredentialBridge(binding.webView)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        val webViewState = Bundle()
        binding.webView.saveState(webViewState)
        outState.putBundle(STATE_WEB_VIEW, webViewState)
        outState.putString(
            STATE_CURRENT_URL,
            pendingNavigationUrl ?: currentNavigationUrl ?: binding.webView.url,
        )
        outState.putBoolean(STATE_DESKTOP_SITE, desktopSite)
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
        binding.webView.apply {
            stopLoading()
            webChromeClient = null
            webViewClient = android.webkit.WebViewClient()
            destroy()
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

    private fun configureWebView() = with(binding.webView) {
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
            setAcceptThirdPartyCookies(this@with, false)
        }
        mobileUserAgent = settings.userAgentString
        settings.userAgentString = "$mobileUserAgent XanhBrowser/1.0"
        webViewClient = XanhWebViewClient(this@BrowserActivity)
        webChromeClient = XanhWebChromeClient(this@BrowserActivity)
        setDownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
            enqueueDownload(url, userAgent, contentDisposition, mimeType)
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
                if (binding.webView.canGoBack()) binding.webView.goBack() else finish()
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
            binding.webView.loadUrl(resolved)
        }
    }

    internal fun onPageStarted(url: String?) {
        syncFeature.navigationStarted(url)
        if (!url.isNullOrBlank() && url != "about:blank") {
            currentNavigationUrl = url
            pendingNavigationUrl = null
        }
        onProgress(0)
    }

    internal fun onPageChanged(url: String?, title: String?) {
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
            preferences.edit { putString(LAST_URL, url) }
            supportActionBar?.subtitle = title
        }
    }

    internal fun onProgress(progress: Int) {
        binding.loadingProgress.progress = progress
        binding.loadingProgress.visibility = if (progress in 0..99) android.view.View.VISIBLE else android.view.View.GONE
    }

    @VisibleForTesting
    internal fun loadWebUrlForTest(url: String) = loadUrlOrSearch(url)

    @VisibleForTesting
    internal fun currentWebUrlForTest(): String? = binding.webView.url

    internal fun openExternal(uri: Uri): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        return if (intent.resolveActivity(packageManager) != null) {
            startActivity(intent)
            true
        } else {
            Toast.makeText(this, R.string.no_app_for_link, Toast.LENGTH_SHORT).show()
            false
        }
    }

    internal fun chooseFiles(
        callback: ValueCallback<Array<Uri>>,
        acceptTypes: Array<String>,
    ): Boolean {
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

    private fun requestDesktopSite(enabled: Boolean, reload: Boolean = true) = with(binding.webView.settings) {
        desktopSite = enabled
        userAgentString = if (enabled) {
            mobileUserAgent.replace("; wv", "").replace(" Mobile", "") + " XanhBrowser/1.0"
        } else {
            "$mobileUserAgent XanhBrowser/1.0"
        }
        useWideViewPort = enabled
        loadWithOverviewMode = enabled
        if (reload) binding.webView.reload()
    }

    private fun clearPrivateData() {
        WebStorage.getInstance().deleteAllData()
        clearLegacyWebViewCredentials()
        binding.webView.apply {
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
        val url = binding.webView.url ?: return
        val share = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, url)
            putExtra(Intent.EXTRA_TITLE, binding.webView.title)
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
        val candidate = pendingNavigationUrl ?: currentNavigationUrl ?: binding.webView.url
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
            if (binding.webView.canGoBack()) binding.webView.goBack()
            true
        }
        R.id.action_forward -> {
            if (binding.webView.canGoForward()) binding.webView.goForward()
            true
        }
        R.id.action_reload -> {
            binding.webView.reload()
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
            syncFeature.open(binding.webView.url, binding.webView.title)
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
        private const val STATE_WEB_VIEW = "state_web_view"
        private const val STATE_CURRENT_URL = "state_current_url"
        private const val STATE_DESKTOP_SITE = "state_desktop_site"
    }
}
