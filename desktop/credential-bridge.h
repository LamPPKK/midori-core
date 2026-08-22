/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef XANH_CREDENTIAL_BRIDGE_H
#define XANH_CREDENTIAL_BRIDGE_H

#include <gio/gio.h>
#include <webkit/webkit.h>

G_BEGIN_DECLS

#define XANH_TYPE_CREDENTIAL_BRIDGE (xanh_credential_bridge_get_type ())
G_DECLARE_FINAL_TYPE (
    XanhCredentialBridge,
    xanh_credential_bridge,
    XANH,
    CREDENTIAL_BRIDGE,
    GObject)

/* Installs a document-start, top-frame-only script and message handler in a
 * named isolated WebKitScriptWorld. Private tabs must not construct a bridge. */
XanhCredentialBridge *xanh_credential_bridge_new (
    WebKitUserContentManager *manager,
    WebKitWebView *web_view,
    GError **error);

/* Shared by the bridge and its policy regression test. */
gboolean xanh_credential_bridge_context_is_safe (
    const gchar *document_url,
    const gchar *origin);

gboolean xanh_credential_bridge_request_is_current (
    XanhCredentialBridge *self,
    const gchar *request_id,
    const gchar *navigation_nonce,
    const gchar *document_url,
    const gchar *origin);
void xanh_credential_bridge_cancel_request (
    XanhCredentialBridge *self,
    const gchar *request_id);

/* Secrets are passed as GVariant arguments directly into the isolated world;
 * they are never interpolated into JavaScript source. */
void xanh_credential_bridge_fill_async (
    XanhCredentialBridge *self,
    const gchar *request_id,
    const gchar *navigation_nonce,
    const gchar *document_url,
    const gchar *origin,
    const gchar *username,
    const gchar *password,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
gboolean xanh_credential_bridge_fill_finish (
    XanhCredentialBridge *self,
    GAsyncResult *result,
    GError **error);

G_END_DECLS

#endif
