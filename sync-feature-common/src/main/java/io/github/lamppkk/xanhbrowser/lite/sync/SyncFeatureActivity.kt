package io.github.lamppkk.xanhbrowser.lite.sync

import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.lifecycle.lifecycleScope
import io.github.lamppkk.xanhbrowser.sync.AccountServer
import io.github.lamppkk.xanhbrowser.sync.AccountState
import io.github.lamppkk.xanhbrowser.sync.SyncEngine
import io.github.lamppkk.xanhbrowser.sync.SyncReason
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SyncFeatureActivity : AppCompatActivity() {
    private val coordinator by lazy { LiteSyncCoordinator.get(this) }
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar
    private lateinit var signIn: Button
    private lateinit var syncNow: Button
    private lateinit var passwords: Button
    private val engineChecks = mutableMapOf<SyncEngine, CheckBox>()

    private val currentUrl get() = intent.getStringExtra(EXTRA_CURRENT_URL)
    private val currentTitle get() = intent.getStringExtra(EXTRA_CURRENT_TITLE)
    private val redirectUri get() = requireNotNull(intent.getStringExtra(EXTRA_REDIRECT_URI))
    private val deviceName get() = intent.getStringExtra(EXTRA_DEVICE_NAME).orEmpty().ifBlank { "Xanh Browser Lite" }
    private val hostedClientId get() = intent.getStringExtra(EXTRA_CLIENT_ID).orEmpty()
    private val hostedAllowed get() = intent.getBooleanExtra(EXTRA_MOZILLA_APPROVED, false) &&
        !intent.getBooleanExtra(EXTRA_SELF_HOSTED_ONLY, false) && hostedClientId.isNotBlank()
    private val isWpe get() = intent.getBooleanExtra(EXTRA_WPE, false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.setTitle(R.string.sync_title)
        LiteSyncProcessObserver.install(application)
        setContentView(buildContent())
        bindActions()
    }

    override fun onStart() {
        super.onStart()
        render()
        lifecycleScope.launch {
            val connected = withContext(Dispatchers.IO) {
                if (coordinator.snapshot()?.accountState != AccountState.CONNECTED) return@withContext false
                coordinator.recordCurrentVisit(currentUrl, currentTitle)
                coordinator.isDue(SyncReason.STARTUP)
            }
            if (connected) performSync(SyncReason.STARTUP, announce = false)
        }
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    private fun buildContent(): View {
        val density = resources.displayMetrics.density
        val padding = (20 * density).toInt()
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
        }
        status = TextView(this)
        progress = ProgressBar(this).apply { visibility = View.GONE }
        signIn = Button(this).apply { setText(R.string.sync_sign_in) }
        syncNow = Button(this).apply { setText(R.string.sync_now) }
        content.addView(status)
        content.addView(progress)
        content.addView(signIn)
        content.addView(Button(this).apply {
            setText(R.string.sync_self_hosted)
            setOnClickListener { configureSelfHosted() }
        })
        SyncEngine.entries.forEach { engine ->
            val label = when (engine) {
                SyncEngine.BOOKMARKS -> R.string.sync_engine_bookmarks
                SyncEngine.HISTORY -> R.string.sync_engine_history
                SyncEngine.TABS -> R.string.sync_engine_tabs
                SyncEngine.PASSWORDS -> R.string.sync_engine_passwords
            }
            content.addView(CheckBox(this).apply {
                setText(label)
                isChecked = true
                engineChecks[engine] = this
            })
        }
        content.addView(syncNow)
        content.addView(Button(this).apply {
            setText(R.string.sync_bookmark_current)
            setOnClickListener { bookmarkCurrent() }
        })
        content.addView(Button(this).apply {
            setText(R.string.sync_remote_tabs)
            setOnClickListener { showRemoteTabs() }
        })
        content.addView(Button(this).apply {
            setText(R.string.sync_unlock)
            setOnClickListener { unlockVault(openPasswords = false) }
        })
        passwords = Button(this).apply {
            setText(R.string.sync_passwords)
            setOnClickListener { openPasswords() }
        }
        content.addView(passwords)
        if (isWpe) content.addView(TextView(this).apply { setText(R.string.sync_wpe_passwords_blocked) })
        content.addView(Button(this).apply {
            setText(R.string.sync_disconnect)
            setOnClickListener { chooseDisconnect() }
        })
        return ScrollView(this).apply { addView(content) }
    }

    private fun bindActions() {
        signIn.setOnClickListener {
            if (hostedAllowed) confirmAndBegin(AccountServer.Mozilla, hostedClientId)
            else configureSelfHosted()
        }
        syncNow.setOnClickListener { performSync(SyncReason.MANUAL, announce = true) }
        engineChecks.forEach { (engine, check) ->
            check.setOnCheckedChangeListener { _, enabled -> coordinator.setEngineEnabled(engine, enabled) }
        }
    }

    private fun confirmAndBegin(server: AccountServer, clientId: String) {
        val domain = when (server) {
            AccountServer.Mozilla -> "accounts.firefox.com"
            is AccountServer.SelfHosted -> runCatching { java.net.URI(server.accountsUrl).host }.getOrNull()
        } ?: return showFailure()
        AlertDialog.Builder(this)
            .setTitle(R.string.sync_sign_in)
            .setMessage(getString(R.string.sync_server_confirm, domain))
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                lifecycleScope.launch {
                    progress.visibility = View.VISIBLE
                    runCatching {
                        withContext(Dispatchers.IO) {
                            coordinator.configure(server, clientId, redirectUri, deviceName)
                            coordinator.beginOAuth()
                        }
                    }.onSuccess { oauthUrl ->
                        coordinator.schedule()
                        CustomTabsIntent.Builder().build().launchUrl(this@SyncFeatureActivity, oauthUrl.toUri())
                    }.onFailure { showFailure() }
                    progress.visibility = View.GONE
                    render()
                }
            }
            .show()
    }

    private fun configureSelfHosted() {
        val accounts = EditText(this).apply {
            hint = getString(R.string.sync_accounts_url)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        }
        val token = EditText(this).apply {
            hint = getString(R.string.sync_token_url)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        }
        val clientId = EditText(this).apply { hint = getString(R.string.sync_client_id) }
        val fields = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(accounts)
            addView(token)
            addView(clientId)
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.sync_self_hosted)
            .setView(fields)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val server = AccountServer.SelfHosted(
                    accounts.text.toString().trim(),
                    token.text.toString().trim(),
                )
                val id = clientId.text.toString().trim()
                runCatching { io.github.lamppkk.xanhbrowser.sync.SyncConfiguration(server, id, redirectUri, deviceName).validate() }
                    .onSuccess { confirmAndBegin(server, id) }
                    .onFailure { Toast.makeText(this, R.string.sync_invalid_configuration, Toast.LENGTH_LONG).show() }
            }
            .show()
    }

    private fun performSync(reason: SyncReason, announce: Boolean) {
        lifecycleScope.launch {
            progress.visibility = View.VISIBLE
            runCatching {
                withContext(Dispatchers.IO) { coordinator.sync(reason, currentUrl, currentTitle) }
            }.onSuccess {
                if (announce) Toast.makeText(this@SyncFeatureActivity, it.status.name, Toast.LENGTH_SHORT).show()
            }.onFailure { showFailure() }
            progress.visibility = View.GONE
            render()
        }
    }

    private fun bookmarkCurrent() {
        lifecycleScope.launch {
            val saved = withContext(Dispatchers.IO) { coordinator.bookmarkCurrent(currentUrl, currentTitle) }
            Toast.makeText(
                this@SyncFeatureActivity,
                if (saved) R.string.sync_saved else R.string.sync_failed,
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    private fun showRemoteTabs() {
        lifecycleScope.launch {
            val rows = withContext(Dispatchers.IO) {
                coordinator.remoteTabs().flatMap { client ->
                    client.remoteTabs.mapNotNull { tab ->
                        val url = tab.urlHistory.firstOrNull()
                            ?.takeIf(::isSafeRemoteUrl)
                            ?: return@mapNotNull null
                        "${client.clientName} — ${tab.title.ifBlank { url }}\n$url" to url
                    }
                }
            }
            if (rows.isEmpty()) {
                Toast.makeText(this@SyncFeatureActivity, R.string.sync_no_remote_tabs, Toast.LENGTH_SHORT).show()
            } else {
                AlertDialog.Builder(this@SyncFeatureActivity)
                    .setTitle(R.string.sync_remote_tabs)
                    .setItems(rows.map { it.first }.toTypedArray()) { _, index ->
                        startActivity(
                            Intent(Intent.ACTION_VIEW, rows[index].second.toUri()).setPackage(packageName),
                        )
                    }
                    .setPositiveButton(android.R.string.ok, null)
                    .show()
            }
        }
    }

    private fun unlockVault(openPasswords: Boolean) {
        val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    lifecycleScope.launch {
                        val unlocked = withContext(Dispatchers.IO) { runCatching { coordinator.unlockVault() } }
                        unlocked.onFailure { showFailure() }
                        if (unlocked.isSuccess && openPasswords) openPasswordActivity()
                        render()
                    }
                }
            },
        )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle(getString(R.string.sync_unlock_title))
                .setSubtitle(getString(R.string.sync_unlock_subtitle))
                .setAllowedAuthenticators(authenticators)
                .build(),
        )
    }

    private fun openPasswords() {
        if (coordinator.snapshot()?.vaultUnlocked == true) openPasswordActivity()
        else unlockVault(openPasswords = true)
    }

    private fun openPasswordActivity() {
        startActivity(Intent(this, SyncPasswordActivity::class.java))
    }

    private fun chooseDisconnect() {
        AlertDialog.Builder(this)
            .setTitle(R.string.sync_disconnect)
            .setSingleChoiceItems(
                arrayOf(getString(R.string.sync_keep_local), getString(R.string.sync_delete_local)),
                0,
                null,
            )
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.sync_disconnect) { dialog, _ ->
                val delete = (dialog as AlertDialog).listView.checkedItemPosition == 1
                lifecycleScope.launch {
                    withContext(Dispatchers.IO) { coordinator.disconnect(delete) }
                    render()
                }
            }
            .show()
    }

    private fun render() {
        lifecycleScope.launch {
            val snapshot = withContext(Dispatchers.IO) { coordinator.snapshot() }
            status.text = when (snapshot?.accountState) {
                AccountState.CONNECTED -> getString(R.string.sync_connected, snapshot.status.name)
                AccountState.AUTHENTICATING -> getString(R.string.sync_authenticating)
                AccountState.AUTH_ISSUES -> getString(R.string.sync_auth_issues)
                else -> getString(R.string.sync_disconnected)
            }
            val connected = snapshot?.accountState == AccountState.CONNECTED
            syncNow.isEnabled = connected
            passwords.isEnabled = connected
            signIn.isEnabled = !connected
            engineChecks.forEach { (engine, check) ->
                check.setOnCheckedChangeListener(null)
                check.isChecked = snapshot?.enabledEngines?.contains(engine) ?: true
                check.setOnCheckedChangeListener { _, enabled -> coordinator.setEngineEnabled(engine, enabled) }
            }
        }
    }

    private fun showFailure() {
        Toast.makeText(this, R.string.sync_failed, Toast.LENGTH_LONG).show()
    }

    private fun isSafeRemoteUrl(value: String): Boolean = runCatching {
        val uri = value.toUri()
        (uri.scheme == "https" || uri.scheme == "http") && !uri.host.isNullOrBlank() && uri.userInfo == null
    }.getOrDefault(false)

    companion object {
        const val EXTRA_CURRENT_URL = "xanh.sync.current_url"
        const val EXTRA_CURRENT_TITLE = "xanh.sync.current_title"
        const val EXTRA_REDIRECT_URI = "xanh.sync.redirect_uri"
        const val EXTRA_DEVICE_NAME = "xanh.sync.device_name"
        const val EXTRA_CLIENT_ID = "xanh.sync.client_id"
        const val EXTRA_MOZILLA_APPROVED = "xanh.sync.mozilla_approved"
        const val EXTRA_SELF_HOSTED_ONLY = "xanh.sync.self_hosted_only"
        const val EXTRA_WPE = "xanh.sync.wpe"
    }
}
