package io.github.lamppkk.xanhbrowser.lite.webkit

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.KeyEvent
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.edit
import androidx.core.net.toUri
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import io.github.lamppkk.xanhbrowser.backup.PortableBackup
import io.github.lamppkk.xanhbrowser.backup.PortableBackupPayload
import io.github.lamppkk.xanhbrowser.lite.webkit.databinding.ActivityWebkitBrowserBinding
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.wpewebkit.wpeview.WPEChromeClient
import org.wpewebkit.wpeview.WPECookieManager
import org.wpewebkit.wpeview.WPEView
import org.wpewebkit.wpeview.WPEViewClient

class WebKitBrowserActivity : AppCompatActivity() {
    private lateinit var binding: ActivityWebkitBrowserBinding
    private val preferences by lazy { getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE) }
    private var desktopSite = false
    private var mobileUserAgent = ""
    private var currentUrl: String? = null
    private var pendingBackupPassword: CharArray? = null

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivityWebkitBrowserBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)
        applyInsets()
        configureWebKit()
        configureAddressBar()
        configureBackNavigation()

        desktopSite = savedInstanceState?.getBoolean(STATE_DESKTOP_SITE) ?: false
        if (desktopSite) requestDesktopSite(true, reload = false)
        val startUrl = savedInstanceState?.getString(STATE_CURRENT_URL)
            ?: WebKitAddressResolver.resolveWebIntent(intent.dataString)
            ?: preferences.getString(LAST_URL, null)
            ?: getString(R.string.app_website)
        loadUrlOrSearch(startUrl)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        WebKitAddressResolver.resolveWebIntent(intent.dataString)?.let(::loadUrlOrSearch)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_CURRENT_URL, currentUrl ?: binding.webView.url)
        outState.putBoolean(STATE_DESKTOP_SITE, desktopSite)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        pendingBackupPassword?.fill('\u0000')
        pendingBackupPassword = null
        binding.webView.apply {
            stopLoading()
            setWPEChromeClient(null)
            setWPEViewClient(WPEViewClient())
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

    private fun configureWebKit() = with(binding.webView) {
        settings.apply {
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
            developerExtrasEnabled = false
            disableWebSecurity = false
            mediaPlaybackRequiresUserGesture = true
        }
        cookieManager.cookieAcceptPolicy = WPECookieManager.CookieAcceptPolicy.AcceptNoThirdParty
        mobileUserAgent = settings.userAgentString.orEmpty()
        settings.setUserAgentString(appendXanhUserAgent(mobileUserAgent, desktop = false))

        setWPEViewClient(object : WPEViewClient() {
            override fun onPageStarted(view: WPEView, url: String) {
                if (url != "about:blank" && !WebKitAddressResolver.isValidWebUrl(url)) {
                    view.stopLoading()
                    view.loadUrl(currentUrl ?: WebKitAddressResolver.HOME_URL)
                    Toast.makeText(
                        this@WebKitBrowserActivity,
                        R.string.blocked_unsafe_navigation,
                        Toast.LENGTH_SHORT,
                    ).show()
                    return
                }
                if (WebKitAddressResolver.isValidWebUrl(url)) currentUrl = url
                onProgress(0)
            }

            override fun onPageFinished(view: WPEView, url: String) {
                if (WebKitAddressResolver.isValidWebUrl(url)) {
                    currentUrl = url
                    binding.urlBar.setText(url)
                    preferences.edit { putString(LAST_URL, url) }
                }
                supportActionBar?.subtitle = view.title
                onProgress(100)
            }

            override fun onReceivedSslError(
                view: WPEView,
                handler: SslErrorHandler,
                error: android.net.http.SslError,
            ) {
                handler.cancel()
                Toast.makeText(this@WebKitBrowserActivity, R.string.tls_error, Toast.LENGTH_LONG).show()
            }
        })
        setWPEChromeClient(object : WPEChromeClient {
            override fun onProgressChanged(view: WPEView, newProgress: Int) = onProgress(newProgress)

            override fun onReceivedTitle(view: WPEView, title: String) {
                supportActionBar?.subtitle = title
            }
        })
    }

    private fun configureAddressBar() {
        binding.urlBar.setOnEditorActionListener { view, actionId, event ->
            val submitted = actionId == EditorInfo.IME_ACTION_GO ||
                (event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
            if (submitted) {
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                    .hideSoftInputFromWindow(view.windowToken, 0)
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

    private fun loadUrlOrSearch(input: String) {
        val resolved = WebKitAddressResolver.resolve(input)
        if (WebKitAddressResolver.isExternal(resolved)) {
            openExternal(resolved.toUri())
            return
        }
        currentUrl = resolved.takeIf(WebKitAddressResolver::isValidWebUrl)
        binding.webView.loadUrl(resolved)
    }

    private fun openExternal(uri: Uri) {
        val external = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        if (external.resolveActivity(packageManager) != null) startActivity(external)
        else Toast.makeText(this, R.string.no_app_for_link, Toast.LENGTH_SHORT).show()
    }

    private fun onProgress(progress: Int) {
        binding.loadingProgress.progress = progress
        binding.loadingProgress.visibility = if (progress in 0..99) View.VISIBLE else View.GONE
    }

    private fun requestDesktopSite(enabled: Boolean, reload: Boolean = true) {
        desktopSite = enabled
        binding.webView.settings.setUserAgentString(appendXanhUserAgent(mobileUserAgent, enabled))
        if (reload) binding.webView.reload()
    }

    private fun appendXanhUserAgent(base: String, desktop: Boolean): String {
        val normalized = if (desktop) {
            base.replace("; wv", "").replace(" Mobile", "")
        } else {
            base
        }
        return "$normalized XanhBrowserWebKit/1.0"
    }

    private fun sharePage() {
        val url = currentUrl ?: binding.webView.url ?: return
        val share = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, url)
            putExtra(Intent.EXTRA_TITLE, binding.webView.title)
        }
        startActivity(Intent.createChooser(share, getString(R.string.share)))
    }

    private fun clearCookies() {
        binding.webView.cookieManager.removeAllCookies {
            preferences.edit { remove(LAST_URL) }
            runOnUiThread {
                Toast.makeText(this, R.string.cookies_cleared, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun chooseBackupDestination() {
        promptBackupPassword(R.string.export_backup) { password ->
            pendingBackupPassword?.fill('\u0000')
            pendingBackupPassword = password
            createBackupDocument.launch("xanh-browser-lite-webkit-${System.currentTimeMillis()}${PortableBackup.FILE_EXTENSION}")
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
        val candidate = currentUrl ?: binding.webView.url
        val url = candidate?.takeIf(PortableBackup::isSupportedWebUrl)
            ?: getString(R.string.app_website)
        val payload = PortableBackupPayload(
            createdAtEpochMillis = System.currentTimeMillis(),
            sourceEdition = "android-lite-webkit",
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
                this@WebKitBrowserActivity,
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
                Toast.makeText(this@WebKitBrowserActivity, R.string.backup_imported, Toast.LENGTH_SHORT).show()
            }.onFailure {
                Toast.makeText(this@WebKitBrowserActivity, R.string.backup_failed, Toast.LENGTH_SHORT).show()
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
        menuInflater.inflate(R.menu.webkit_app_menu, menu)
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
        R.id.action_clear_cookies -> {
            clearCookies()
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
        R.id.action_engine_information -> {
            AlertDialog.Builder(this)
                .setTitle(R.string.engine_information)
                .setMessage(
                    getString(
                        R.string.engine_information_message,
                        getString(R.string.wpe_runtime_version),
                        getString(R.string.wpe_view_version),
                    ),
                )
                .setPositiveButton(android.R.string.ok, null)
                .show()
            true
        }
        R.id.action_app_settings -> {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:$packageName".toUri()))
            true
        }
        else -> super.onOptionsItemSelected(item)
    }

    companion object {
        private const val PREFERENCES = "xanh_browser_webkit"
        private const val LAST_URL = "last_url"
        private const val STATE_CURRENT_URL = "state_current_url"
        private const val STATE_DESKTOP_SITE = "state_desktop_site"
    }
}
