package io.github.lamppkk.xanhbrowser.lite.sync

import android.os.Bundle
import android.text.InputType
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import io.github.lamppkk.xanhbrowser.sync.XanhSyncRuntime
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import mozilla.appservices.logins.Login
import mozilla.appservices.logins.LoginEntry

class SyncPasswordActivity : AppCompatActivity() {
    private lateinit var runtime: XanhSyncRuntime
    private lateinit var list: ListView
    private var logins: List<Login> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        LiteSyncProcessObserver.install(application)
        val available = LiteSyncCoordinator.get(this).runtimeOrNull()
        if (available?.snapshot()?.vaultUnlocked != true || available.loginsOrNull() == null) {
            Toast.makeText(this, R.string.sync_vault_locked, Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        runtime = available
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.setTitle(R.string.sync_passwords)
        list = ListView(this)
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(Button(this@SyncPasswordActivity).apply {
                setText(R.string.sync_add_password)
                setOnClickListener { editLogin(null) }
            })
            addView(list, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        })
        list.setOnItemClickListener { _, _, position, _ -> editLogin(logins[position]) }
        list.setOnItemLongClickListener { _, _, position, _ ->
            confirmDelete(logins[position])
            true
        }
    }

    override fun onStart() {
        super.onStart()
        if (::runtime.isInitialized && runtime.touchVault()) refresh() else if (::runtime.isInitialized) finish()
    }

    override fun onStop() {
        logins = emptyList()
        if (::list.isInitialized) list.adapter = null
        super.onStop()
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    private fun refresh() {
        lifecycleScope.launch {
            val loaded = withContext(Dispatchers.IO) { runtime.loginsOrNull()?.list().orEmpty() }
            if (!runtime.touchVault()) {
                finish()
                return@launch
            }
            logins = loaded.sortedWith(compareBy(Login::origin, Login::username))
            list.adapter = ArrayAdapter(
                this@SyncPasswordActivity,
                android.R.layout.simple_list_item_1,
                logins.map { "${it.origin} — ${it.username.ifBlank { getString(R.string.sync_empty_username) }}" },
            )
        }
    }

    private fun editLogin(existing: Login?) {
        if (!runtime.touchVault()) return finish()
        val origin = EditText(this).apply {
            hint = getString(R.string.sync_password_origin)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText(existing?.origin.orEmpty())
        }
        val username = EditText(this).apply {
            hint = getString(R.string.sync_password_username)
            setText(existing?.username.orEmpty())
        }
        val password = EditText(this).apply {
            hint = getString(R.string.sync_password_value)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(existing?.password.orEmpty())
        }
        AlertDialog.Builder(this)
            .setTitle(if (existing == null) R.string.sync_add_password else R.string.sync_edit_password)
            .setView(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                addView(origin)
                addView(username)
                addView(password)
            })
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val canonical = canonicalHttpsOrigin(origin.text.toString())
                val secret = password.text.toString()
                if (canonical == null || secret.isEmpty()) {
                    Toast.makeText(this, R.string.sync_password_invalid, Toast.LENGTH_LONG).show()
                    return@setPositiveButton
                }
                val entry = LoginEntry(
                    origin = canonical,
                    httpRealm = null,
                    formActionOrigin = canonical,
                    usernameField = "",
                    passwordField = "",
                    password = secret,
                    username = username.text.toString(),
                )
                lifecycleScope.launch {
                    withContext(Dispatchers.IO) {
                        val store = checkNotNull(runtime.loginsOrNull())
                        if (existing == null) store.add(entry) else store.update(existing.id, entry)
                        runtime.recordLocalChange()
                    }
                    refresh()
                }
            }
            .show()
    }

    private fun confirmDelete(login: Login) {
        AlertDialog.Builder(this)
            .setTitle(R.string.sync_delete_password)
            .setMessage(login.origin)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.sync_delete_password) { _, _ ->
                lifecycleScope.launch {
                    withContext(Dispatchers.IO) {
                        runtime.loginsOrNull()?.delete(login.id)
                        runtime.recordLocalChange()
                    }
                    refresh()
                }
            }
            .show()
    }

    private fun canonicalHttpsOrigin(value: String): String? = runCatching {
        val uri = URI(value.trim())
        require(uri.scheme.equals("https", true) && uri.host != null && uri.userInfo == null)
        URI("https", null, uri.host, uri.port, null, null, null).toASCIIString()
    }.getOrNull()
}
