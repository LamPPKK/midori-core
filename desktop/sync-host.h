/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef XANH_SYNC_HOST_H
#define XANH_SYNC_HOST_H

#include <gio/gio.h>

G_BEGIN_DECLS

#define XANH_TYPE_SYNC_HOST (xanh_sync_host_get_type ())
G_DECLARE_FINAL_TYPE (XanhSyncHost, xanh_sync_host, XANH, SYNC_HOST, GObject)

typedef enum {
    XANH_SYNC_HOST_ERROR_UNAVAILABLE,
    XANH_SYNC_HOST_ERROR_CORE,
    XANH_SYNC_HOST_ERROR_SECRET_SERVICE,
    XANH_SYNC_HOST_ERROR_INVALID_REDIRECT,
    XANH_SYNC_HOST_ERROR_BUSY,
    XANH_SYNC_HOST_ERROR_BACKED_OFF,
    XANH_SYNC_HOST_ERROR_HISTORY_CLEARED
} XanhSyncHostError;

#define XANH_SYNC_HOST_ERROR (xanh_sync_host_error_quark ())
GQuark xanh_sync_host_error_quark (void);

/* Sync reason values intentionally match xanh-sync-core's stable C ABI. */
typedef enum {
    XANH_SYNC_REASON_STARTUP = 0,
    XANH_SYNC_REASON_MANUAL = 1,
    XANH_SYNC_REASON_SCHEDULED = 2,
    XANH_SYNC_REASON_LOCAL_CHANGE = 3,
    XANH_SYNC_REASON_PRE_SLEEP = 4
} XanhSyncReason;

XanhSyncHost *xanh_sync_host_new (const gchar *profile_dir);

/* Atomically persists a non-secret local recovery marker with file and parent
 * directory durability before a destructive native operation begins. */
gboolean xanh_sync_write_durable_marker (const gchar *path, GError **error);
gboolean xanh_sync_remove_durable_marker (const gchar *path, GError **error);

gboolean xanh_sync_host_is_configured (XanhSyncHost *self);
gboolean xanh_sync_host_is_ready (XanhSyncHost *self);
gint xanh_sync_host_account_state (XanhSyncHost *self);
gchar *xanh_sync_host_dup_account_domain (XanhSyncHost *self);
gchar *xanh_sync_host_dup_status (XanhSyncHost *self);

/* Returns TRUE only for the exact registered callback origin/path. Query
 * parameters are validated by complete_redirect_async before they reach Rust. */
gboolean xanh_sync_host_is_redirect_uri (XanhSyncHost *self, const gchar *uri);
gboolean xanh_sync_host_validate_redirect_uri (
    XanhSyncHost *self,
    const gchar *uri,
    GError **error);

void xanh_sync_host_initialize_async (
    XanhSyncHost *self,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_initialize_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);

void xanh_sync_host_begin_oauth_async (
    XanhSyncHost *self,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_begin_oauth_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);

void xanh_sync_host_complete_redirect_async (
    XanhSyncHost *self,
    const gchar *redirect_uri,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_complete_redirect_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);

gboolean xanh_sync_host_sync_due (
    XanhSyncHost *self,
    XanhSyncReason reason,
    gint64 now_epoch_seconds);
void xanh_sync_host_mark_local_change (
    XanhSyncHost *self,
    gint64 now_epoch_seconds);
void xanh_sync_host_sync_async (
    XanhSyncHost *self,
    XanhSyncReason reason,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_sync_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);

void xanh_sync_host_import_legacy_bookmarks_async (
    XanhSyncHost *self,
    const gchar *bookmarks_json,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_import_legacy_bookmarks_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_bookmarks_json_async (
    XanhSyncHost *self,
    gint root,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_bookmarks_json_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_delete_bookmark_async (
    XanhSyncHost *self,
    const gchar *guid,
    gboolean is_private,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_delete_bookmark_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_record_history_async (
    XanhSyncHost *self,
    const gchar *visits_json,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_record_history_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_recent_history_json_async (
    XanhSyncHost *self,
    guint limit,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_recent_history_json_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_delete_history_visit_async (
    XanhSyncHost *self,
    const gchar *url,
    gint64 visited_at_epoch_millis,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_delete_history_visit_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_clear_history_async (
    XanhSyncHost *self,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_clear_history_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_update_local_tabs_async (
    XanhSyncHost *self,
    const gchar *tabs_json,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_update_local_tabs_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_remote_tabs_json_async (
    XanhSyncHost *self,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_remote_tabs_json_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);

/* Plaintext returned by credentials_json_finish is short-lived secret
 * material. The caller must never log, cache or persist it. */
void xanh_sync_host_credentials_json_async (
    XanhSyncHost *self,
    const gchar *context_json,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gchar *xanh_sync_host_credentials_json_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
void xanh_sync_host_touch_credential_async (
    XanhSyncHost *self,
    const gchar *credential_id,
    const gchar *context_json,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_touch_credential_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);

void xanh_sync_host_unlock_vault_async (
    XanhSyncHost *self,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_unlock_vault_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);
gboolean xanh_sync_host_lock_vault (XanhSyncHost *self, GError **error);
gboolean xanh_sync_host_vault_unlocked (XanhSyncHost *self);
void xanh_sync_host_touch_vault (XanhSyncHost *self);

void xanh_sync_host_disconnect_async (
    XanhSyncHost *self,
    gboolean delete_local,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_sync_host_disconnect_finish (
    XanhSyncHost *self,
    GAsyncResult *result,
    GError **error);

G_END_DECLS

#endif
