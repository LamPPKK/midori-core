/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "sync-host.h"

#include <errno.h>
#include <glib/gstdio.h>
#include <json-glib/json-glib.h>

#ifdef XANH_ENABLE_FIREFOX_SYNC
#include <libsecret/secret.h>
#include <xanh_sync.h>
#endif

#define XANH_SYNC_REDIRECT_SCHEME "xanh-browser"
#define XANH_SYNC_REDIRECT_HOST "accounts"
#define XANH_SYNC_REDIRECT_PATH "/oauth"
#define XANH_SYNC_REDIRECT_URI "xanh-browser://accounts/oauth"
#define XANH_SYNC_INTERVAL_SECONDS (15 * 60)
#define XANH_SYNC_LOCAL_DEBOUNCE_SECONDS 30
#define XANH_SYNC_VAULT_TIMEOUT_SECONDS (5 * 60)

struct _XanhSyncHost {
    GObject parent_instance;
    GMutex mutex;
#ifdef XANH_ENABLE_FIREFOX_SYNC
    GMutex operation_mutex;
#endif
    gchar *profile_dir;
    gchar *profile_id;
    gchar *config_json;
    gchar *account_domain;
    gchar *status;
    gboolean configured;
    gint account_state;
    gint64 last_sync_epoch_seconds;
    gint64 next_sync_allowed_epoch_seconds;
    gint64 local_change_epoch_seconds;
#ifdef XANH_ENABLE_FIREFOX_SYNC
    gpointer runtime;
    gint sync_running;
    gint vault_unlocked;
    gint vault_lock_pending;
    gint vault_lock_generation;
    gboolean disconnect_cleanup_pending;
    gboolean disconnect_native_pending;
    gboolean disconnect_delete_local;
    gint64 vault_last_touched_monotonic;
    guint vault_timeout_source;
#endif
};

G_DEFINE_TYPE (XanhSyncHost, xanh_sync_host, G_TYPE_OBJECT)

G_DEFINE_QUARK (xanh-sync-host-error-quark, xanh_sync_host_error)

#ifdef XANH_ENABLE_FIREFOX_SYNC
static const SecretSchema sync_secret_schema = {
    .name = "io.github.lamppkk.xanhbrowser.FirefoxSync",
    .flags = SECRET_SCHEMA_NONE,
    .attributes = {
        { "profile", SECRET_SCHEMA_ATTRIBUTE_STRING },
        { "item", SECRET_SCHEMA_ATTRIBUTE_STRING },
        { NULL, 0 }
    }
};

typedef struct {
    gchar *redirect_uri;
    XanhSyncReason reason;
    gboolean delete_local;
    gint vault_lock_generation;
} SyncTaskData;

static void
sync_task_data_free (SyncTaskData *data)
{
    if (data == NULL)
        return;
    g_clear_pointer (&data->redirect_uri, g_free);
    g_free (data);
}
#endif

static void
set_status_locked (XanhSyncHost *self,
                   const gchar  *status)
{
    g_free (self->status);
    self->status = g_strdup (status != NULL ? status : "");
}

static gboolean
parse_redirect_uri (const gchar  *value,
                    gboolean      require_parameters,
                    gchar       **code_out,
                    gchar       **state_out,
                    GError      **error)
{
    g_autoptr (GUri) uri = NULL;
    g_autofree gchar *code = NULL;
    g_autofree gchar *state = NULL;
    const gchar *query;

    if (value == NULL || *value == '\0') {
        g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                             XANH_SYNC_HOST_ERROR_INVALID_REDIRECT,
                             "Firefox Accounts redirect is empty");
        return FALSE;
    }

    uri = g_uri_parse (value, G_URI_FLAGS_NONE, error);
    if (uri == NULL)
        return FALSE;
    if (g_strcmp0 (g_uri_get_scheme (uri), XANH_SYNC_REDIRECT_SCHEME) != 0 ||
        g_strcmp0 (g_uri_get_host (uri), XANH_SYNC_REDIRECT_HOST) != 0 ||
        g_strcmp0 (g_uri_get_path (uri), XANH_SYNC_REDIRECT_PATH) != 0 ||
        g_uri_get_port (uri) != -1 ||
        g_uri_get_userinfo (uri) != NULL ||
        g_uri_get_fragment (uri) != NULL) {
        g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                             XANH_SYNC_HOST_ERROR_INVALID_REDIRECT,
                             "Firefox Accounts redirect origin or path does not match");
        return FALSE;
    }
    if (!require_parameters)
        return TRUE;

    query = g_uri_get_query (uri);
    if (query != NULL) {
        GUriParamsIter iter;
        GError *parameter_error = NULL;
        gchar *name = NULL;
        gchar *parameter_value = NULL;

        g_uri_params_iter_init (&iter, query, -1, "&", G_URI_PARAMS_NONE);
        while (g_uri_params_iter_next (&iter, &name, &parameter_value,
                                       &parameter_error)) {
            if (g_strcmp0 (name, "code") == 0) {
                if (code != NULL) {
                    g_free (name);
                    g_free (parameter_value);
                    g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                                         XANH_SYNC_HOST_ERROR_INVALID_REDIRECT,
                                         "Firefox Accounts redirect repeats code");
                    return FALSE;
                }
                code = g_strdup (parameter_value);
            } else if (g_strcmp0 (name, "state") == 0) {
                if (state != NULL) {
                    g_free (name);
                    g_free (parameter_value);
                    g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                                         XANH_SYNC_HOST_ERROR_INVALID_REDIRECT,
                                         "Firefox Accounts redirect repeats state");
                    return FALSE;
                }
                state = g_strdup (parameter_value);
            }
            g_free (name);
            g_free (parameter_value);
            name = NULL;
            parameter_value = NULL;
        }
        if (parameter_error != NULL) {
            g_propagate_prefixed_error (error, parameter_error,
                                        "Invalid Firefox Accounts redirect: ");
            return FALSE;
        }
    }

    if (code == NULL || *code == '\0' || state == NULL || *state == '\0') {
        g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                             XANH_SYNC_HOST_ERROR_INVALID_REDIRECT,
                             "Firefox Accounts redirect requires one code and state");
        return FALSE;
    }
    if (code_out != NULL)
        *code_out = g_steal_pointer (&code);
    if (state_out != NULL)
        *state_out = g_steal_pointer (&state);
    return TRUE;
}

#ifdef XANH_ENABLE_FIREFOX_SYNC
static gchar *
json_builder_to_string (JsonBuilder *builder)
{
    g_autoptr (JsonGenerator) generator = json_generator_new ();
    g_autoptr (JsonNode) root = json_builder_get_root (builder);
    json_generator_set_root (generator, root);
    return json_generator_to_data (generator, NULL);
}

static gchar *
endpoint_domain (const gchar *endpoint)
{
    g_autoptr (GUri) uri = g_uri_parse (endpoint, G_URI_FLAGS_NONE, NULL);
    return uri != NULL && g_uri_get_host (uri) != NULL
        ? g_strdup (g_uri_get_host (uri)) : NULL;
}

static gboolean
build_configuration (XanhSyncHost *self)
{
    const gchar *client_id = g_getenv ("XANH_FXA_CLIENT_ID");
    const gchar *accounts_url = g_getenv ("XANH_FXA_ACCOUNTS_URL");
    const gchar *token_server_url = g_getenv ("XANH_FXA_TOKEN_SERVER_URL");
    gboolean self_hosted = accounts_url != NULL || token_server_url != NULL;
    gboolean approved = g_strcmp0 (g_getenv ("XANH_FXA_PRODUCTION_APPROVED"), "1") == 0;
    g_autoptr (JsonBuilder) builder = json_builder_new ();
    const gchar *host_name;

    if (client_id == NULL || *client_id == '\0') {
        set_status_locked (self, "Firefox Sync needs a registered client ID");
        return FALSE;
    }
    if (self_hosted &&
        (accounts_url == NULL || *accounts_url == '\0' ||
         token_server_url == NULL || *token_server_url == '\0')) {
        set_status_locked (self,
                           "Self-hosted Sync needs both HTTPS Accounts and Token Server URLs");
        return FALSE;
    }
    if (!self_hosted && !approved) {
        set_status_locked (self,
                           "Mozilla-hosted Sync remains disabled until production approval");
        return FALSE;
    }

    json_builder_begin_object (builder);
    json_builder_set_member_name (builder, "server");
    json_builder_begin_object (builder);
    json_builder_set_member_name (builder, "kind");
    json_builder_add_string_value (builder, self_hosted ? "self-hosted" : "mozilla");
    if (self_hosted) {
        json_builder_set_member_name (builder, "accounts_url");
        json_builder_add_string_value (builder, accounts_url);
        json_builder_set_member_name (builder, "token_server_url");
        json_builder_add_string_value (builder, token_server_url);
    }
    json_builder_end_object (builder);
    json_builder_set_member_name (builder, "client_id");
    json_builder_add_string_value (builder, client_id);
    json_builder_set_member_name (builder, "redirect_uri");
    json_builder_add_string_value (builder, XANH_SYNC_REDIRECT_URI);
    json_builder_set_member_name (builder, "device_name");
    host_name = g_get_host_name ();
    json_builder_add_string_value (builder,
                                   host_name != NULL && *host_name != '\0'
                                       ? host_name : "Xanh Browser Linux");
    json_builder_set_member_name (builder, "device_kind");
    json_builder_add_string_value (builder, "desktop");
    json_builder_end_object (builder);

    self->config_json = json_builder_to_string (builder);
    self->account_domain = self_hosted
        ? endpoint_domain (accounts_url)
        : g_strdup ("accounts.firefox.com");
    if (self->account_domain == NULL) {
        g_clear_pointer (&self->config_json, g_free);
        set_status_locked (self, "Firefox Accounts endpoint has no valid domain");
        return FALSE;
    }
    set_status_locked (self, "Firefox Sync is ready to initialize");
    return TRUE;
}

static GError *
core_error (const gchar *fallback)
{
    gchar *detail = xanh_sync_last_error ();
    GError *error;
    /* Application Services error strings are intentionally never forwarded to
     * the UI or GLib diagnostics: upstream messages may contain endpoints or
     * credential-adjacent request data. Keep only the reviewed host message. */
    xanh_sync_string_free (detail);
    error = g_error_new_literal (XANH_SYNC_HOST_ERROR,
                                 XANH_SYNC_HOST_ERROR_CORE, fallback);
    return error;
}

static gboolean
ensure_secret_service (GCancellable *cancellable,
                       GError      **error)
{
    SecretService *service = secret_service_get_sync (
        SECRET_SERVICE_OPEN_SESSION, cancellable, error);
    if (service == NULL) {
        if (error != NULL && *error != NULL)
            g_prefix_error (error, "Secret Service unavailable: ");
        return FALSE;
    }
    g_object_unref (service);
    return TRUE;
}

static gchar *
lookup_secret (XanhSyncHost *self,
               const gchar  *item,
               GCancellable *cancellable,
               GError      **error)
{
    gchar *value = secret_password_lookup_sync (
        &sync_secret_schema, cancellable, error,
        "profile", self->profile_id,
        "item", item,
        NULL);
    if (error != NULL && *error != NULL)
        g_prefix_error (error, "Cannot read Firefox Sync secure state: ");
    return value;
}

static gboolean
store_secret (XanhSyncHost *self,
              const gchar  *item,
              const gchar  *value,
              GCancellable *cancellable,
              GError      **error)
{
    gboolean result;
    if (value == NULL) {
        result = secret_password_clear_sync (
            &sync_secret_schema, cancellable, error,
            "profile", self->profile_id,
            "item", item,
            NULL);
    } else {
        result = secret_password_store_sync (
            &sync_secret_schema, SECRET_COLLECTION_DEFAULT,
            "Xanh Browser Firefox Sync", value, cancellable, error,
            "profile", self->profile_id,
            "item", item,
            NULL);
    }
    if (!result) {
        if (error != NULL && *error != NULL)
            g_prefix_error (error, "Cannot update Firefox Sync secure state: ");
        else
            g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                                 XANH_SYNC_HOST_ERROR_SECRET_SERVICE,
                                 "Cannot update Firefox Sync secure state");
    }
    return result;
}

static gboolean
parse_positive_epoch (const gchar *value,
                      gint64      *result)
{
    gchar *end = NULL;
    guint64 parsed;
    if (value == NULL || *value == '\0')
        return FALSE;
    errno = 0;
    parsed = g_ascii_strtoull (value, &end, 10);
    if (errno != 0 || end == NULL || *end != '\0' || parsed > G_MAXINT64)
        return FALSE;
    *result = (gint64) parsed;
    return TRUE;
}

static gboolean
persist_account (XanhSyncHost *self,
                 gpointer      runtime,
                 GCancellable *cancellable,
                 GError      **error)
{
    gchar *account = xanh_sync_runtime_account_json (runtime);
    gboolean result;
    if (account == NULL) {
        g_propagate_error (error, core_error ("Cannot serialize Firefox Account state"));
        return FALSE;
    }
    result = store_secret (self, "account-json", account, cancellable, error);
    xanh_sync_string_free (account);
    return result;
}

static gboolean
persist_sync_state (XanhSyncHost *self,
                    gpointer      runtime,
                    GCancellable *cancellable,
                    GError      **error)
{
    gchar *state = xanh_sync_runtime_persisted_state (runtime);
    gboolean result = store_secret (self, "sync-state", state, cancellable, error);
    xanh_sync_string_free (state);
    return result;
}

static gboolean
persist_account_status (XanhSyncHost *self,
                        gint          account_state,
                        GCancellable *cancellable,
                        GError      **error)
{
    return store_secret (self, "account-status",
                         account_state == 3 ? "auth-issues" : NULL,
                         cancellable, error);
}

static gboolean
persist_schedule (XanhSyncHost *self,
                  gint64        last_sync_epoch_seconds,
                  gint64        next_sync_allowed_epoch_seconds,
                  GCancellable *cancellable,
                  GError      **error)
{
    g_autofree gchar *last = last_sync_epoch_seconds > 0
        ? g_strdup_printf ("%" G_GINT64_FORMAT, last_sync_epoch_seconds)
        : NULL;
    g_autofree gchar *next = next_sync_allowed_epoch_seconds > 0
        ? g_strdup_printf ("%" G_GINT64_FORMAT, next_sync_allowed_epoch_seconds)
        : NULL;
    return store_secret (self, "last-sync", last, cancellable, error) &&
           store_secret (self, "next-allowed", next, cancellable, error);
}

static gboolean
remove_local_logins_database (XanhSyncHost *self,
                              GError      **error)
{
    const gchar *suffixes[] = { "", "-wal", "-shm", NULL };
    guint index;

    for (index = 0; suffixes[index] != NULL; index++) {
        g_autofree gchar *name = g_strconcat ("logins.sqlite", suffixes[index], NULL);
        g_autofree gchar *path = g_build_filename (self->profile_dir, name, NULL);
        if (g_unlink (path) != 0 && errno != ENOENT) {
            g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                         "Cannot reset the unreadable local password database");
            return FALSE;
        }
    }
    return TRUE;
}

/* Called while operation_mutex is held. A focus-loss request never waits for
 * a network operation on the GTK thread; the worker applies it before making
 * the runtime available to another operation. */
static gboolean
apply_pending_vault_lock (XanhSyncHost *self,
                          GError      **error)
{
    gpointer runtime;

    if (!g_atomic_int_compare_and_exchange (&self->vault_lock_pending, 1, 0))
        return TRUE;
    g_mutex_lock (&self->mutex);
    runtime = self->runtime;
    g_mutex_unlock (&self->mutex);
    if (runtime != NULL && !xanh_sync_runtime_lock_vault (runtime)) {
        GError *lock_error = core_error ("Cannot lock the password vault");
        g_atomic_int_set (&self->vault_lock_pending, 1);
        if (error != NULL)
            g_propagate_error (error, lock_error);
        else
            g_error_free (lock_error);
        return FALSE;
    }
    g_atomic_int_set (&self->vault_unlocked, 0);
    g_mutex_lock (&self->mutex);
    set_status_locked (self, "Password vault locked");
    g_mutex_unlock (&self->mutex);
    return TRUE;
}

static void
finish_operation (XanhSyncHost *self)
{
    g_autoptr (GError) ignored = NULL;
    apply_pending_vault_lock (self, &ignored);
    g_mutex_unlock (&self->operation_mutex);
}

static void
vault_lock_worker (GTask        *task,
                   gpointer      source_object,
                   gpointer      task_data,
                   GCancellable *cancellable)
{
    XanhSyncHost *self = XANH_SYNC_HOST (source_object);
    g_autoptr (GError) error = NULL;

    g_mutex_lock (&self->operation_mutex);
    if (!apply_pending_vault_lock (self, &error)) {
        g_mutex_unlock (&self->operation_mutex);
        g_task_return_error (task, g_steal_pointer (&error));
        return;
    }
    g_mutex_unlock (&self->operation_mutex);
    g_task_return_boolean (task, TRUE);
}

static void
queue_vault_lock (XanhSyncHost *self)
{
    GTask *task = g_task_new (self, NULL, NULL, NULL);
    g_task_run_in_thread (task, vault_lock_worker);
    g_object_unref (task);
}

static gboolean
require_runtime_locked (XanhSyncHost *self,
                        GError      **error)
{
    if (self->runtime != NULL)
        return TRUE;
    g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                         XANH_SYNC_HOST_ERROR_UNAVAILABLE,
                         "Firefox Sync runtime is not initialized");
    return FALSE;
}

static void
initialize_worker (GTask        *task,
                   gpointer      source_object,
                   gpointer      task_data,
                   GCancellable *cancellable)
{
    XanhSyncHost *self = XANH_SYNC_HOST (source_object);
    g_autoptr (GError) error = NULL;
    gchar *account = NULL;
    gchar *sync_state = NULL;
    gchar *last = NULL;
    gchar *next = NULL;
    gchar *account_status = NULL;
    gpointer runtime = NULL;
    gint state;
    gint64 last_epoch = 0;
    gint64 next_epoch = 0;

    if (g_task_return_error_if_cancelled (task))
        return;
    g_mutex_lock (&self->operation_mutex);
    g_mutex_lock (&self->mutex);
    if (self->runtime != NULL) {
        g_mutex_unlock (&self->mutex);
        finish_operation (self);
        g_task_return_boolean (task, TRUE);
        return;
    }
    g_mutex_unlock (&self->mutex);
    if (!ensure_secret_service (cancellable, &error))
        goto fail;
    if (g_mkdir_with_parents (self->profile_dir, 0700) != 0) {
        g_set_error (&error, G_FILE_ERROR, g_file_error_from_errno (errno),
                     "Cannot create Firefox Sync profile directory");
        goto fail;
    }
    if (g_chmod (self->profile_dir, 0700) != 0) {
        g_set_error (&error, G_FILE_ERROR, g_file_error_from_errno (errno),
                     "Cannot protect Firefox Sync profile directory");
        goto fail;
    }

    account = lookup_secret (self, "account-json", cancellable, &error);
    if (error != NULL)
        goto fail;
    sync_state = lookup_secret (self, "sync-state", cancellable, &error);
    if (error != NULL)
        goto fail;
    last = lookup_secret (self, "last-sync", cancellable, &error);
    if (error != NULL)
        goto fail;
    next = lookup_secret (self, "next-allowed", cancellable, &error);
    if (error != NULL)
        goto fail;
    account_status = lookup_secret (self, "account-status", cancellable, &error);
    if (error != NULL)
        goto fail;

    runtime = xanh_sync_runtime_open (
        self->config_json, self->profile_dir, NULL, account, sync_state);
    if (runtime == NULL) {
        error = core_error ("Cannot open Firefox Sync runtime");
        goto fail;
    }
    state = xanh_sync_runtime_initialize (runtime);
    if (state < 0) {
        error = core_error ("Cannot initialize Firefox Account state");
        goto fail;
    }
    if (g_strcmp0 (account_status, "auth-issues") == 0)
        state = 3;
    if (!persist_account (self, runtime, cancellable, &error))
        goto fail;

    parse_positive_epoch (last, &last_epoch);
    parse_positive_epoch (next, &next_epoch);
    g_mutex_lock (&self->mutex);
    self->runtime = runtime;
    runtime = NULL;
    self->account_state = state;
    self->last_sync_epoch_seconds = last_epoch;
    self->next_sync_allowed_epoch_seconds = next_epoch;
    set_status_locked (self, state == 2 ? "Firefox Sync connected" :
                       state == 3 ? "Firefox Account needs attention" :
                                    "Firefox Sync disconnected");
    g_mutex_unlock (&self->mutex);
    g_atomic_int_set (&self->vault_unlocked, 0);
    secret_password_free (account);
    secret_password_free (sync_state);
    secret_password_free (last);
    secret_password_free (next);
    secret_password_free (account_status);
    finish_operation (self);
    g_task_return_boolean (task, TRUE);
    return;

fail:
    if (runtime != NULL)
        xanh_sync_runtime_free (runtime);
    g_mutex_lock (&self->mutex);
    set_status_locked (self, "Firefox Sync initialization failed");
    g_mutex_unlock (&self->mutex);
    secret_password_free (account);
    secret_password_free (sync_state);
    secret_password_free (last);
    secret_password_free (next);
    secret_password_free (account_status);
    finish_operation (self);
    g_task_return_error (task, g_steal_pointer (&error));
}

static void
begin_oauth_worker (GTask        *task,
                    gpointer      source_object,
                    gpointer      task_data,
                    GCancellable *cancellable)
{
    XanhSyncHost *self = XANH_SYNC_HOST (source_object);
    g_autoptr (GError) error = NULL;
    gchar *url;
    gpointer runtime;
    gint account_state;

    if (g_task_return_error_if_cancelled (task))
        return;
    g_mutex_lock (&self->operation_mutex);
    g_mutex_lock (&self->mutex);
    if (!require_runtime_locked (self, &error))
        goto fail;
    runtime = self->runtime;
    g_mutex_unlock (&self->mutex);
    url = xanh_sync_runtime_begin_oauth (runtime);
    if (url == NULL) {
        error = core_error ("Cannot begin Firefox Accounts OAuth");
        goto fail_unlocked;
    }
    account_state = xanh_sync_runtime_account_state (runtime);
    if (!persist_account (self, runtime, cancellable, &error) ||
        !persist_account_status (self, account_state, cancellable, &error)) {
        gboolean disconnected = xanh_sync_runtime_disconnect (runtime, FALSE);
        g_mutex_lock (&self->mutex);
        self->account_state = 3;
        self->disconnect_delete_local = FALSE;
        self->disconnect_native_pending = !disconnected;
        self->disconnect_cleanup_pending = disconnected;
        g_mutex_unlock (&self->mutex);
        xanh_sync_string_free (url);
        goto fail_unlocked;
    }
    g_mutex_lock (&self->mutex);
    self->account_state = account_state;
    set_status_locked (self, "Complete sign-in in the system browser");
    g_mutex_unlock (&self->mutex);
    finish_operation (self);
    g_task_return_pointer (task, g_strdup (url), g_free);
    xanh_sync_string_free (url);
    return;

fail:
    g_mutex_unlock (&self->mutex);
fail_unlocked:
    finish_operation (self);
    g_task_return_error (task, g_steal_pointer (&error));
}

static void
complete_redirect_worker (GTask        *task,
                          gpointer      source_object,
                          gpointer      task_data,
                          GCancellable *cancellable)
{
    XanhSyncHost *self = XANH_SYNC_HOST (source_object);
    SyncTaskData *data = task_data;
    g_autoptr (GError) error = NULL;
    g_autofree gchar *code = NULL;
    g_autofree gchar *state = NULL;
    gint account_state;
    gpointer runtime;

    if (g_task_return_error_if_cancelled (task))
        return;
    if (!parse_redirect_uri (data->redirect_uri, TRUE, &code, &state, &error)) {
        g_task_return_error (task, g_steal_pointer (&error));
        return;
    }
    g_mutex_lock (&self->operation_mutex);
    g_mutex_lock (&self->mutex);
    if (!require_runtime_locked (self, &error))
        goto fail;
    runtime = self->runtime;
    g_mutex_unlock (&self->mutex);
    account_state = xanh_sync_runtime_complete_oauth (runtime, code, state);
    if (account_state < 0) {
        error = core_error ("Cannot complete Firefox Accounts OAuth");
        goto fail_unlocked;
    }
    if (!persist_account (self, runtime, cancellable, &error) ||
        !persist_account_status (self, account_state, cancellable, &error)) {
        gboolean disconnected = xanh_sync_runtime_disconnect (runtime, FALSE);
        g_mutex_lock (&self->mutex);
        self->account_state = 3;
        self->disconnect_delete_local = FALSE;
        self->disconnect_native_pending = !disconnected;
        self->disconnect_cleanup_pending = disconnected;
        g_mutex_unlock (&self->mutex);
        goto fail_unlocked;
    }
    g_mutex_lock (&self->mutex);
    self->account_state = account_state;
    set_status_locked (self, account_state == 2
        ? "Firefox Sync connected" : "Firefox Account needs attention");
    g_mutex_unlock (&self->mutex);
    finish_operation (self);
    g_task_return_boolean (task, account_state == 2);
    return;

fail:
    g_mutex_unlock (&self->mutex);
fail_unlocked:
    finish_operation (self);
    g_task_return_error (task, g_steal_pointer (&error));
}

static gboolean
parse_sync_result_locked (XanhSyncHost *self,
                          const gchar  *value,
                          gint64        now,
                          GError      **error)
{
    g_autoptr (JsonParser) parser = json_parser_new ();
    JsonNode *root;
    JsonObject *object;
    const gchar *status;

    if (!json_parser_load_from_data (parser, value, -1, error))
        return FALSE;
    root = json_parser_get_root (parser);
    if (root == NULL || !JSON_NODE_HOLDS_OBJECT (root)) {
        g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                             XANH_SYNC_HOST_ERROR_CORE,
                             "Firefox Sync returned an invalid result");
        return FALSE;
    }
    object = json_node_get_object (root);
    status = json_object_get_string_member_with_default (object, "status", "partial");
    self->last_sync_epoch_seconds = now;
    self->local_change_epoch_seconds = 0;
    self->next_sync_allowed_epoch_seconds = 0;
    if (json_object_has_member (object, "next_sync_allowed_epoch_seconds") &&
        !JSON_NODE_HOLDS_NULL (json_object_get_member (object, "next_sync_allowed_epoch_seconds"))) {
        self->next_sync_allowed_epoch_seconds = json_object_get_int_member (
            object, "next_sync_allowed_epoch_seconds");
    }
    if (g_strcmp0 (status, "success") == 0)
        set_status_locked (self, "Firefox Sync completed");
    else if (g_strcmp0 (status, "backed-off") == 0)
        set_status_locked (self, "Firefox Sync is respecting server backoff");
    else if (g_strcmp0 (status, "auth-error") == 0) {
        self->account_state = 3;
        set_status_locked (self, "Firefox Account needs attention");
    } else
        set_status_locked (self, "Firefox Sync completed partially");
    return TRUE;
}

static void
sync_worker (GTask        *task,
             gpointer      source_object,
             gpointer      task_data,
             GCancellable *cancellable)
{
    XanhSyncHost *self = XANH_SYNC_HOST (source_object);
    SyncTaskData *data = task_data;
    g_autoptr (GError) error = NULL;
    gchar *core_result = NULL;
    gchar *result = NULL;
    gint64 now = g_get_real_time () / G_USEC_PER_SEC;
    gint64 last_sync = 0;
    gint64 next_allowed = 0;
    const gchar *engines;
    gpointer runtime;
    gboolean operation_locked = FALSE;
    gint account_state = 0;

    if (g_task_return_error_if_cancelled (task))
        goto done;
    g_mutex_lock (&self->operation_mutex);
    operation_locked = TRUE;
    g_mutex_lock (&self->mutex);
    if (!require_runtime_locked (self, &error))
        goto fail_locked;
    if (self->account_state != 2) {
        g_set_error_literal (&error, XANH_SYNC_HOST_ERROR,
                             XANH_SYNC_HOST_ERROR_UNAVAILABLE,
                             "Firefox Account is not connected");
        goto fail_locked;
    }
    if (self->next_sync_allowed_epoch_seconds > now) {
        g_set_error (&error, XANH_SYNC_HOST_ERROR,
                     XANH_SYNC_HOST_ERROR_BACKED_OFF,
                     "Firefox Sync is backed off until %" G_GINT64_FORMAT,
                     self->next_sync_allowed_epoch_seconds);
        goto fail_locked;
    }
    runtime = self->runtime;
    engines = g_atomic_int_get (&self->vault_unlocked)
        ? "[\"bookmarks\",\"history\",\"tabs\",\"passwords\"]"
        : "[\"bookmarks\",\"history\",\"tabs\"]";
    g_mutex_unlock (&self->mutex);

    core_result = xanh_sync_runtime_sync (runtime, data->reason, engines);
    if (core_result == NULL) {
        error = core_error ("Firefox Sync failed");
        g_mutex_lock (&self->mutex);
        self->account_state = xanh_sync_runtime_account_state (runtime);
        set_status_locked (self, self->account_state == 3
            ? "Firefox Account needs attention" : "Firefox Sync failed");
        g_mutex_unlock (&self->mutex);
        goto fail_unlocked;
    }
    g_mutex_lock (&self->mutex);
    self->account_state = xanh_sync_runtime_account_state (runtime);
    if (!parse_sync_result_locked (self, core_result, now, &error))
        goto fail_locked;
    last_sync = self->last_sync_epoch_seconds;
    next_allowed = self->next_sync_allowed_epoch_seconds;
    account_state = self->account_state;
    g_mutex_unlock (&self->mutex);

    if (!persist_account (self, runtime, cancellable, &error) ||
        !persist_account_status (self, account_state, cancellable, &error) ||
        !persist_sync_state (self, runtime, cancellable, &error) ||
        !persist_schedule (self, last_sync, next_allowed, cancellable, &error)) {
        g_mutex_lock (&self->mutex);
        set_status_locked (self, "Firefox Sync state could not be saved securely");
        g_mutex_unlock (&self->mutex);
        goto fail_unlocked;
    }
    result = g_strdup (core_result);
    xanh_sync_string_free (core_result);
    core_result = NULL;
    finish_operation (self);
    operation_locked = FALSE;
    g_task_return_pointer (task, result, g_free);
    goto done;

fail_locked:
    set_status_locked (self, self->account_state == 3
        ? "Firefox Account needs attention" : "Firefox Sync failed");
    g_mutex_unlock (&self->mutex);
fail_unlocked:
    if (core_result != NULL)
        xanh_sync_string_free (core_result);
    if (operation_locked)
        finish_operation (self);
    g_task_return_error (task, g_steal_pointer (&error));

done:
    g_atomic_int_set (&self->sync_running, 0);
}

static gboolean
vault_timeout_cb (gpointer user_data)
{
    XanhSyncHost *self = XANH_SYNC_HOST (user_data);
    gboolean remove = FALSE;
    gint64 elapsed;

    g_mutex_lock (&self->mutex);
    elapsed = (g_get_monotonic_time () - self->vault_last_touched_monotonic) /
              G_USEC_PER_SEC;
    if (self->runtime == NULL ||
        !g_atomic_int_get (&self->vault_unlocked) ||
        elapsed >= XANH_SYNC_VAULT_TIMEOUT_SECONDS) {
        self->vault_last_touched_monotonic = 0;
        self->vault_timeout_source = 0;
        remove = TRUE;
    }
    g_mutex_unlock (&self->mutex);
    if (remove)
        xanh_sync_host_lock_vault (self, NULL);
    return remove ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
}

static void
schedule_vault_timeout (XanhSyncHost *self)
{
    g_mutex_lock (&self->mutex);
    if (self->vault_timeout_source != 0)
        g_source_remove (self->vault_timeout_source);
    self->vault_timeout_source = g_timeout_add_seconds_full (
        G_PRIORITY_DEFAULT, 30, vault_timeout_cb,
        g_object_ref (self), g_object_unref);
    g_mutex_unlock (&self->mutex);
}

static void
unlock_vault_worker (GTask        *task,
                     gpointer      source_object,
                     gpointer      task_data,
                     GCancellable *cancellable)
{
    XanhSyncHost *self = XANH_SYNC_HOST (source_object);
    SyncTaskData *data = task_data;
    g_autoptr (GError) error = NULL;
    gchar *stored_key = NULL;
    gchar *generated_key = NULL;
    const gchar *key;
    gpointer runtime;
    gboolean generated = FALSE;

    if (g_task_return_error_if_cancelled (task))
        return;
    g_mutex_lock (&self->operation_mutex);
    g_mutex_lock (&self->mutex);
    if (!require_runtime_locked (self, &error))
        goto fail;
    runtime = self->runtime;
    g_mutex_unlock (&self->mutex);
    stored_key = lookup_secret (self, "logins-key", cancellable, &error);
    if (error != NULL)
        goto fail_unlocked;
    if (stored_key == NULL) {
        if (!remove_local_logins_database (self, &error))
            goto fail_unlocked;
        generated_key = xanh_sync_generate_local_logins_key ();
        if (generated_key == NULL) {
            error = core_error ("Cannot generate the local password-vault key");
            goto fail_unlocked;
        }
        generated = TRUE;
    }
    key = stored_key != NULL ? stored_key : generated_key;
    if (!xanh_sync_runtime_unlock_vault (runtime, key)) {
        error = core_error ("Cannot unlock the local password vault");
        goto fail_unlocked;
    }
    if (generated &&
        !store_secret (self, "logins-key", generated_key, cancellable, &error)) {
        xanh_sync_runtime_lock_vault (runtime);
        goto fail_unlocked;
    }
    if (data->vault_lock_generation !=
        g_atomic_int_get (&self->vault_lock_generation)) {
        g_atomic_int_set (&self->vault_lock_pending, 1);
        if (!apply_pending_vault_lock (self, &error)) {
            g_prefix_error (&error, "Unlock cancellation could not close the vault: ");
        } else {
            error = g_error_new_literal (
                XANH_SYNC_HOST_ERROR, XANH_SYNC_HOST_ERROR_UNAVAILABLE,
                "Password vault unlock was cancelled when the application lost focus");
        }
        goto fail_unlocked;
    }
    g_atomic_int_set (&self->vault_unlocked, 1);
    g_mutex_lock (&self->mutex);
    self->vault_last_touched_monotonic = g_get_monotonic_time ();
    set_status_locked (self, "Password vault unlocked for five minutes");
    g_mutex_unlock (&self->mutex);
    secret_password_free (stored_key);
    xanh_sync_string_free (generated_key);
    finish_operation (self);
    if (!g_atomic_int_get (&self->vault_unlocked)) {
        g_task_return_new_error (
            task, XANH_SYNC_HOST_ERROR, XANH_SYNC_HOST_ERROR_UNAVAILABLE,
            "Password vault was locked before unlock completed");
        return;
    }
    g_task_return_boolean (task, TRUE);
    return;

fail:
    g_mutex_unlock (&self->mutex);
fail_unlocked:
    secret_password_free (stored_key);
    xanh_sync_string_free (generated_key);
    finish_operation (self);
    g_task_return_error (task, g_steal_pointer (&error));
}

static void
disconnect_worker (GTask        *task,
                   gpointer      source_object,
                   gpointer      task_data,
                   GCancellable *cancellable)
{
    XanhSyncHost *self = XANH_SYNC_HOST (source_object);
    SyncTaskData *data = task_data;
    g_autoptr (GError) error = NULL;
    const gchar *items[] = {
        "account-json", "account-status", "sync-state", "last-sync", "next-allowed", NULL
    };
    guint index;
    gpointer runtime;
    gboolean delete_local;
    gboolean call_native;

    if (g_task_return_error_if_cancelled (task))
        return;
    g_mutex_lock (&self->operation_mutex);
    g_mutex_lock (&self->mutex);
    if (!require_runtime_locked (self, &error))
        goto fail;
    runtime = self->runtime;
    if (!self->disconnect_native_pending && !self->disconnect_cleanup_pending) {
        self->disconnect_delete_local = data->delete_local;
        self->disconnect_native_pending = self->account_state != 0;
    }
    delete_local = self->disconnect_delete_local;
    call_native = self->disconnect_native_pending;
    g_mutex_unlock (&self->mutex);

    if (call_native) {
        gboolean disconnected = xanh_sync_runtime_disconnect (runtime, delete_local);
        g_mutex_lock (&self->mutex);
        self->account_state = 3;
        self->disconnect_native_pending = !disconnected;
        self->disconnect_cleanup_pending = disconnected;
        g_mutex_unlock (&self->mutex);
        if (!disconnected) {
            error = core_error ("Cannot disconnect Firefox Sync; retry will preserve the original data choice");
            goto fail_unlocked;
        }
    }
    g_mutex_lock (&self->mutex);
    self->last_sync_epoch_seconds = 0;
    self->next_sync_allowed_epoch_seconds = 0;
    self->local_change_epoch_seconds = 0;
    g_mutex_unlock (&self->mutex);
    for (index = 0; items[index] != NULL; index++) {
        if (!store_secret (self, items[index], NULL, cancellable, &error))
            goto fail_unlocked;
    }
    if (delete_local &&
        !store_secret (self, "logins-key", NULL, cancellable, &error))
        goto fail_unlocked;

    g_mutex_lock (&self->mutex);
    self->runtime = NULL;
    self->disconnect_cleanup_pending = FALSE;
    self->disconnect_native_pending = FALSE;
    self->account_state = 0;
    if (self->vault_timeout_source != 0) {
        g_source_remove (self->vault_timeout_source);
        self->vault_timeout_source = 0;
    }
    set_status_locked (self, delete_local
        ? "Firefox Sync disconnected and local Sync data removed"
        : "Firefox Sync disconnected; local data kept");
    g_mutex_unlock (&self->mutex);
    g_atomic_int_set (&self->vault_unlocked, 0);
    g_atomic_int_set (&self->vault_lock_pending, 0);
    xanh_sync_runtime_free (runtime);
    finish_operation (self);
    g_task_return_boolean (task, TRUE);
    return;

fail:
    g_mutex_unlock (&self->mutex);
fail_unlocked:
    g_mutex_lock (&self->mutex);
    set_status_locked (self, "Firefox Sync disconnect did not complete");
    g_mutex_unlock (&self->mutex);
    finish_operation (self);
    g_task_return_error (task, g_steal_pointer (&error));
}
#endif

static void
return_unavailable (XanhSyncHost      *self,
                    GCancellable      *cancellable,
                    GAsyncReadyCallback callback,
                    gpointer           user_data)
{
    GTask *task = g_task_new (self, cancellable, callback, user_data);
    g_task_return_new_error (task, XANH_SYNC_HOST_ERROR,
                             XANH_SYNC_HOST_ERROR_UNAVAILABLE,
                             "%s", self->status != NULL ? self->status
                                                        : "Firefox Sync is unavailable");
    g_object_unref (task);
}

static void
xanh_sync_host_finalize (GObject *object)
{
    XanhSyncHost *self = XANH_SYNC_HOST (object);
#ifdef XANH_ENABLE_FIREFOX_SYNC
    g_mutex_lock (&self->operation_mutex);
    if (self->vault_timeout_source != 0) {
        g_source_remove (self->vault_timeout_source);
        self->vault_timeout_source = 0;
    }
    g_mutex_lock (&self->mutex);
    if (self->runtime != NULL) {
        xanh_sync_runtime_lock_vault (self->runtime);
        xanh_sync_runtime_free (self->runtime);
        self->runtime = NULL;
    }
    g_mutex_unlock (&self->mutex);
    g_mutex_unlock (&self->operation_mutex);
    g_mutex_clear (&self->operation_mutex);
#endif
    g_mutex_clear (&self->mutex);
    g_clear_pointer (&self->profile_dir, g_free);
    g_clear_pointer (&self->profile_id, g_free);
    g_clear_pointer (&self->config_json, g_free);
    g_clear_pointer (&self->account_domain, g_free);
    g_clear_pointer (&self->status, g_free);
    G_OBJECT_CLASS (xanh_sync_host_parent_class)->finalize (object);
}

static void
xanh_sync_host_class_init (XanhSyncHostClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    object_class->finalize = xanh_sync_host_finalize;
}

static void
xanh_sync_host_init (XanhSyncHost *self)
{
    g_mutex_init (&self->mutex);
#ifdef XANH_ENABLE_FIREFOX_SYNC
    g_mutex_init (&self->operation_mutex);
#endif
    self->account_state = 0;
    self->status = g_strdup ("Firefox Sync is unavailable");
}

XanhSyncHost *
xanh_sync_host_new (const gchar *profile_dir)
{
    XanhSyncHost *self;
    g_return_val_if_fail (profile_dir != NULL && *profile_dir != '\0', NULL);
    self = g_object_new (XANH_TYPE_SYNC_HOST, NULL);
    self->profile_dir = g_canonicalize_filename (profile_dir, NULL);
    self->profile_id = g_compute_checksum_for_string (
        G_CHECKSUM_SHA256, self->profile_dir, -1);
#ifdef XANH_ENABLE_FIREFOX_SYNC
    self->configured = build_configuration (self);
#else
    set_status_locked (self, "This build does not include the Firefox Sync native core");
#endif
    return self;
}

gboolean
xanh_sync_host_is_configured (XanhSyncHost *self)
{
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), FALSE);
    return self->configured;
}

gboolean
xanh_sync_host_is_ready (XanhSyncHost *self)
{
    gboolean ready = FALSE;
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), FALSE);
    g_mutex_lock (&self->mutex);
#ifdef XANH_ENABLE_FIREFOX_SYNC
    ready = self->runtime != NULL;
#endif
    g_mutex_unlock (&self->mutex);
    return ready;
}

gint
xanh_sync_host_account_state (XanhSyncHost *self)
{
    gint state;
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), -1);
    g_mutex_lock (&self->mutex);
    state = self->account_state;
    g_mutex_unlock (&self->mutex);
    return state;
}

gchar *
xanh_sync_host_dup_account_domain (XanhSyncHost *self)
{
    gchar *domain;
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), NULL);
    g_mutex_lock (&self->mutex);
    domain = g_strdup (self->account_domain);
    g_mutex_unlock (&self->mutex);
    return domain;
}

gchar *
xanh_sync_host_dup_status (XanhSyncHost *self)
{
    gchar *status;
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), NULL);
    g_mutex_lock (&self->mutex);
    status = g_strdup (self->status);
    g_mutex_unlock (&self->mutex);
    return status;
}

gboolean
xanh_sync_host_is_redirect_uri (XanhSyncHost *self,
                                const gchar  *uri)
{
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), FALSE);
    return parse_redirect_uri (uri, FALSE, NULL, NULL, NULL);
}

gboolean
xanh_sync_host_validate_redirect_uri (XanhSyncHost *self,
                                      const gchar  *uri,
                                      GError      **error)
{
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), FALSE);
    return parse_redirect_uri (uri, TRUE, NULL, NULL, error);
}

void
xanh_sync_host_initialize_async (XanhSyncHost      *self,
                                 GCancellable      *cancellable,
                                 GAsyncReadyCallback callback,
                                 gpointer           user_data)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
    if (!self->configured) {
        return_unavailable (self, cancellable, callback, user_data);
        return;
    }
#ifdef XANH_ENABLE_FIREFOX_SYNC
    GTask *task = g_task_new (self, cancellable, callback, user_data);
    g_task_run_in_thread (task, initialize_worker);
    g_object_unref (task);
#else
    return_unavailable (self, cancellable, callback, user_data);
#endif
}

gboolean
xanh_sync_host_initialize_finish (XanhSyncHost *self,
                                  GAsyncResult *result,
                                  GError      **error)
{
    g_return_val_if_fail (g_task_is_valid (result, self), FALSE);
    return g_task_propagate_boolean (G_TASK (result), error);
}

void
xanh_sync_host_begin_oauth_async (XanhSyncHost      *self,
                                  GCancellable      *cancellable,
                                  GAsyncReadyCallback callback,
                                  gpointer           user_data)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
#ifdef XANH_ENABLE_FIREFOX_SYNC
    GTask *task = g_task_new (self, cancellable, callback, user_data);
    g_task_run_in_thread (task, begin_oauth_worker);
    g_object_unref (task);
#else
    return_unavailable (self, cancellable, callback, user_data);
#endif
}

gchar *
xanh_sync_host_begin_oauth_finish (XanhSyncHost *self,
                                   GAsyncResult *result,
                                   GError      **error)
{
    g_return_val_if_fail (g_task_is_valid (result, self), NULL);
    return g_task_propagate_pointer (G_TASK (result), error);
}

void
xanh_sync_host_complete_redirect_async (XanhSyncHost      *self,
                                        const gchar       *redirect_uri,
                                        GCancellable      *cancellable,
                                        GAsyncReadyCallback callback,
                                        gpointer           user_data)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
#ifdef XANH_ENABLE_FIREFOX_SYNC
    GTask *task = g_task_new (self, cancellable, callback, user_data);
    SyncTaskData *data = g_new0 (SyncTaskData, 1);
    data->redirect_uri = g_strdup (redirect_uri);
    g_task_set_task_data (task, data, (GDestroyNotify) sync_task_data_free);
    g_task_run_in_thread (task, complete_redirect_worker);
    g_object_unref (task);
#else
    (void) redirect_uri;
    return_unavailable (self, cancellable, callback, user_data);
#endif
}

gboolean
xanh_sync_host_complete_redirect_finish (XanhSyncHost *self,
                                         GAsyncResult *result,
                                         GError      **error)
{
    g_return_val_if_fail (g_task_is_valid (result, self), FALSE);
    return g_task_propagate_boolean (G_TASK (result), error);
}

gboolean
xanh_sync_host_sync_due (XanhSyncHost  *self,
                         XanhSyncReason reason,
                         gint64         now_epoch_seconds)
{
    gboolean due = FALSE;
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), FALSE);
    if (now_epoch_seconds <= 0)
        now_epoch_seconds = g_get_real_time () / G_USEC_PER_SEC;
    g_mutex_lock (&self->mutex);
    if (self->account_state == 2 &&
        self->next_sync_allowed_epoch_seconds <= now_epoch_seconds) {
        switch (reason) {
        case XANH_SYNC_REASON_MANUAL:
        case XANH_SYNC_REASON_PRE_SLEEP:
            due = TRUE;
            break;
        case XANH_SYNC_REASON_STARTUP:
        case XANH_SYNC_REASON_SCHEDULED:
            due = self->last_sync_epoch_seconds == 0 ||
                  now_epoch_seconds - self->last_sync_epoch_seconds >=
                      XANH_SYNC_INTERVAL_SECONDS;
            break;
        case XANH_SYNC_REASON_LOCAL_CHANGE:
            due = self->local_change_epoch_seconds > 0 &&
                  now_epoch_seconds - self->local_change_epoch_seconds >=
                      XANH_SYNC_LOCAL_DEBOUNCE_SECONDS;
            break;
        default:
            due = FALSE;
        }
    }
    g_mutex_unlock (&self->mutex);
    return due;
}

void
xanh_sync_host_mark_local_change (XanhSyncHost *self,
                                  gint64        now_epoch_seconds)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
    if (now_epoch_seconds <= 0)
        now_epoch_seconds = g_get_real_time () / G_USEC_PER_SEC;
    g_mutex_lock (&self->mutex);
    self->local_change_epoch_seconds = now_epoch_seconds;
    g_mutex_unlock (&self->mutex);
}

void
xanh_sync_host_sync_async (XanhSyncHost      *self,
                           XanhSyncReason     reason,
                           GCancellable      *cancellable,
                           GAsyncReadyCallback callback,
                           gpointer           user_data)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
#ifdef XANH_ENABLE_FIREFOX_SYNC
    GTask *task;
    SyncTaskData *data;
    if (!g_atomic_int_compare_and_exchange (&self->sync_running, 0, 1)) {
        task = g_task_new (self, cancellable, callback, user_data);
        g_task_return_new_error (task, XANH_SYNC_HOST_ERROR,
                                 XANH_SYNC_HOST_ERROR_BUSY,
                                 "A Firefox Sync operation is already running");
        g_object_unref (task);
        return;
    }
    task = g_task_new (self, cancellable, callback, user_data);
    data = g_new0 (SyncTaskData, 1);
    data->reason = reason;
    g_task_set_task_data (task, data, (GDestroyNotify) sync_task_data_free);
    g_task_run_in_thread (task, sync_worker);
    g_object_unref (task);
#else
    (void) reason;
    return_unavailable (self, cancellable, callback, user_data);
#endif
}

gchar *
xanh_sync_host_sync_finish (XanhSyncHost *self,
                            GAsyncResult *result,
                            GError      **error)
{
    g_return_val_if_fail (g_task_is_valid (result, self), NULL);
    return g_task_propagate_pointer (G_TASK (result), error);
}

void
xanh_sync_host_unlock_vault_async (XanhSyncHost      *self,
                                   GCancellable      *cancellable,
                                   GAsyncReadyCallback callback,
                                   gpointer           user_data)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
#ifdef XANH_ENABLE_FIREFOX_SYNC
    GTask *task;
    SyncTaskData *data = g_new0 (SyncTaskData, 1);
    data->vault_lock_generation = g_atomic_int_get (&self->vault_lock_generation);
    /* Capture the user's foreground unlock intent at submission time. A later
     * focus-loss request sets this back to 1 while the worker is queued and
     * finish_operation() will then close the freshly opened vault. */
    g_atomic_int_set (&self->vault_lock_pending, 0);
    task = g_task_new (self, cancellable, callback, user_data);
    g_task_set_task_data (task, data, (GDestroyNotify) sync_task_data_free);
    g_task_run_in_thread (task, unlock_vault_worker);
    g_object_unref (task);
#else
    return_unavailable (self, cancellable, callback, user_data);
#endif
}

gboolean
xanh_sync_host_unlock_vault_finish (XanhSyncHost *self,
                                    GAsyncResult *result,
                                    GError      **error)
{
    gboolean unlocked;
    g_return_val_if_fail (g_task_is_valid (result, self), FALSE);
    unlocked = g_task_propagate_boolean (G_TASK (result), error);
#ifdef XANH_ENABLE_FIREFOX_SYNC
    if (unlocked)
        schedule_vault_timeout (self);
#endif
    return unlocked;
}

gboolean
xanh_sync_host_lock_vault (XanhSyncHost *self,
                           GError      **error)
{
    gboolean result = TRUE;
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), FALSE);
#ifdef XANH_ENABLE_FIREFOX_SYNC
    g_mutex_lock (&self->mutex);
    if (self->vault_timeout_source != 0) {
        g_source_remove (self->vault_timeout_source);
        self->vault_timeout_source = 0;
    }
    self->vault_last_touched_monotonic = 0;
    g_mutex_unlock (&self->mutex);
    /* Treat the vault as locked immediately. If a background native operation
     * owns the runtime, it applies the actual close before releasing it. */
    g_atomic_int_set (&self->vault_unlocked, 0);
    g_atomic_int_inc (&self->vault_lock_generation);
    g_atomic_int_set (&self->vault_lock_pending, 1);
    if (g_mutex_trylock (&self->operation_mutex)) {
        result = apply_pending_vault_lock (self, error);
        g_mutex_unlock (&self->operation_mutex);
    } else
        queue_vault_lock (self);
    g_mutex_lock (&self->mutex);
    set_status_locked (self, "Password vault locked");
    g_mutex_unlock (&self->mutex);
#else
    g_set_error_literal (error, XANH_SYNC_HOST_ERROR,
                         XANH_SYNC_HOST_ERROR_UNAVAILABLE,
                         "This build does not include Firefox Sync");
    result = FALSE;
#endif
    return result;
}

gboolean
xanh_sync_host_vault_unlocked (XanhSyncHost *self)
{
    gboolean unlocked = FALSE;
    g_return_val_if_fail (XANH_IS_SYNC_HOST (self), FALSE);
#ifdef XANH_ENABLE_FIREFOX_SYNC
    unlocked = g_atomic_int_get (&self->vault_unlocked);
#endif
    return unlocked;
}

void
xanh_sync_host_touch_vault (XanhSyncHost *self)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
#ifdef XANH_ENABLE_FIREFOX_SYNC
    if (g_atomic_int_get (&self->vault_unlocked)) {
        g_mutex_lock (&self->mutex);
        self->vault_last_touched_monotonic = g_get_monotonic_time ();
        g_mutex_unlock (&self->mutex);
    }
#endif
}

void
xanh_sync_host_disconnect_async (XanhSyncHost      *self,
                                 gboolean           delete_local,
                                 GCancellable      *cancellable,
                                 GAsyncReadyCallback callback,
                                 gpointer           user_data)
{
    g_return_if_fail (XANH_IS_SYNC_HOST (self));
#ifdef XANH_ENABLE_FIREFOX_SYNC
    GTask *task = g_task_new (self, cancellable, callback, user_data);
    SyncTaskData *data = g_new0 (SyncTaskData, 1);
    data->delete_local = delete_local;
    g_task_set_task_data (task, data, (GDestroyNotify) sync_task_data_free);
    g_task_run_in_thread (task, disconnect_worker);
    g_object_unref (task);
#else
    (void) delete_local;
    return_unavailable (self, cancellable, callback, user_data);
#endif
}

gboolean
xanh_sync_host_disconnect_finish (XanhSyncHost *self,
                                  GAsyncResult *result,
                                  GError      **error)
{
    return xanh_sync_host_initialize_finish (self, result, error);
}
