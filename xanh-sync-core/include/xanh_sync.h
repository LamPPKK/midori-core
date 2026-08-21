#ifndef XANH_SYNC_H
#define XANH_SYNC_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returned strings belong to the caller and must be released with
 * xanh_sync_string_free. Sensitive account state crosses this ABI only so the
 * platform adapter can persist it in OS secure storage. */
char *xanh_sync_core_version(void);
void xanh_sync_string_free(char *value);

/* Security-policy primitive shared by Vala, C#, and WinCairo. The JSON must
 * match CredentialContext and is denied closed on every parsing error. */
bool xanh_sync_credential_access_allowed(
    const char *context_json,
    bool vault_unlocked
);

/* Production runtime. `local_logins_key`, account JSON and persisted state are
 * sensitive; obtain/store them only through OS secure storage. Pass NULL for
 * `local_logins_key` to start with the password vault locked. Null return or
 * -1 indicates failure; read and free `xanh_sync_last_error()` for diagnostics.
 * Diagnostics never contain tokens or keys. */
char *xanh_sync_last_error(void);
char *xanh_sync_generate_local_logins_key(void);
void *xanh_sync_runtime_open(
    const char *config_json,
    const char *profile_dir,
    const char *local_logins_key,
    const char *account_json,
    const char *persisted_sync_state
);
void xanh_sync_runtime_free(void *runtime);
int32_t xanh_sync_runtime_initialize(void *runtime);
int32_t xanh_sync_runtime_account_state(void *runtime);
char *xanh_sync_runtime_begin_oauth(void *runtime);
int32_t xanh_sync_runtime_complete_oauth(void *runtime, const char *code, const char *state);
char *xanh_sync_runtime_account_json(void *runtime);
char *xanh_sync_runtime_persisted_state(void *runtime);
bool xanh_sync_runtime_unlock_vault(void *runtime, const char *local_logins_key);
bool xanh_sync_runtime_lock_vault(void *runtime);
bool xanh_sync_runtime_vault_unlocked(void *runtime);
char *xanh_sync_runtime_sync(void *runtime, int32_t reason, const char *engines_json);
/* Replaces the write-only local Tabs state used by the next Sync. `tabs_json`
 * is a JSON array of LocalTab records. Private records are skipped by the core;
 * malformed/unsafe web URLs reject the entire update. The returned JSON is a
 * LocalTabsUpdateResult. */
char *xanh_sync_runtime_update_local_tabs(void *runtime, const char *tabs_json);
/* Returns sanitized remote tabs grouped by device. This is display data only;
 * the host must require an explicit user action before opening any URL. */
char *xanh_sync_runtime_remote_tabs_json(void *runtime);
bool xanh_sync_runtime_disconnect(void *runtime, bool delete_local);

#ifdef __cplusplus
}
#endif

#endif
