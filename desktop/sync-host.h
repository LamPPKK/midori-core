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
    XANH_SYNC_HOST_ERROR_BACKED_OFF
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
