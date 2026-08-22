/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "external-navigation-bridge.h"
#include "external-navigation-data.h"

#define XANH_EXTERNAL_WORLD "io.github.lamppkk.xanhbrowser.external-navigation"
#define XANH_EXTERNAL_HANDLER "xanhExternalNavigation"

struct _XanhExternalNavigationBridge {
    GObject parent_instance;
    WebKitUserContentManager *manager;
    WebKitUserScript *script;
    gulong message_signal;
    gboolean handler_registered;
};

G_DEFINE_TYPE (
    XanhExternalNavigationBridge,
    xanh_external_navigation_bridge,
    G_TYPE_OBJECT)

enum {
    REQUEST,
    LAST_SIGNAL
};

static guint signals[LAST_SIGNAL];

static const gchar bootstrap_source[] =
    "(() => {\n"
    "  if (window.top !== window || globalThis.__xanhExternalNavigationInstalled) return;\n"
    "  const handler = window.webkit?.messageHandlers?.xanhExternalNavigation;\n"
    "  if (!handler) return;\n"
    "  Object.defineProperty(globalThis, '__xanhExternalNavigationInstalled', { value: true });\n"
    "  const schemes = new Set(['mailto:', 'tel:', 'sms:', 'geo:', 'maps:', 'market:']);\n"
    "  globalThis.addEventListener('click', event => {\n"
    "    if (!event.isTrusted || event.defaultPrevented || event.button !== 0 ||\n"
    "        event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;\n"
    "    const path = typeof event.composedPath === 'function' ? event.composedPath() : [];\n"
    "    let anchor = path.find(node => node instanceof HTMLAnchorElement);\n"
    "    if (!anchor && event.target instanceof Element) anchor = event.target.closest('a[href]');\n"
    "    if (!(anchor instanceof HTMLAnchorElement)) return;\n"
    "    let target;\n"
    "    try { target = new URL(anchor.href, document.baseURI); } catch (_) { return; }\n"
    "    if (!schemes.has(target.protocol.toLowerCase())) return;\n"
    "    event.preventDefault();\n"
    "    event.stopImmediatePropagation();\n"
    "    handler.postMessage(JSON.stringify({\n"
    "      externalUrl: target.href, documentUrl: location.href\n"
    "    }));\n"
    "  }, true);\n"
    "})();";

static void
message_received (WebKitUserContentManager *manager,
                  JSCValue                 *value,
                  gpointer                  user_data)
{
    XanhExternalNavigationBridge *self =
        XANH_EXTERNAL_NAVIGATION_BRIDGE (user_data);
    g_autofree gchar *message = NULL;
    g_autofree gchar *external_uri = NULL;
    g_autofree gchar *document_uri = NULL;

    (void) manager;
    if (!jsc_value_is_string (value))
        return;
    message = jsc_value_to_string (value);
    if (!xanh_external_navigation_parse_message (
            message, &external_uri, &document_uri))
        return;
    g_signal_emit (self, signals[REQUEST], 0, external_uri, document_uri);
}

static void
xanh_external_navigation_bridge_dispose (GObject *object)
{
    XanhExternalNavigationBridge *self =
        XANH_EXTERNAL_NAVIGATION_BRIDGE (object);

    if (self->manager != NULL) {
        if (self->message_signal != 0) {
            g_signal_handler_disconnect (self->manager, self->message_signal);
            self->message_signal = 0;
        }
        if (self->handler_registered) {
            webkit_user_content_manager_unregister_script_message_handler (
                self->manager, XANH_EXTERNAL_HANDLER, XANH_EXTERNAL_WORLD);
            self->handler_registered = FALSE;
        }
        if (self->script != NULL)
            webkit_user_content_manager_remove_script (self->manager, self->script);
    }
    g_clear_pointer (&self->script, webkit_user_script_unref);
    g_clear_object (&self->manager);
    G_OBJECT_CLASS (xanh_external_navigation_bridge_parent_class)->dispose (object);
}

static void
xanh_external_navigation_bridge_class_init (XanhExternalNavigationBridgeClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    object_class->dispose = xanh_external_navigation_bridge_dispose;
    signals[REQUEST] = g_signal_new (
        "request", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST,
        0, NULL, NULL, NULL, G_TYPE_NONE, 2,
        G_TYPE_STRING, G_TYPE_STRING);
}

static void
xanh_external_navigation_bridge_init (XanhExternalNavigationBridge *self)
{
    (void) self;
}

XanhExternalNavigationBridge *
xanh_external_navigation_bridge_new (WebKitUserContentManager *manager,
                                     GError                  **error)
{
    static const gchar *allow_list[] = { "http://*/*", "https://*/*", NULL };
    XanhExternalNavigationBridge *self;

    g_return_val_if_fail (WEBKIT_IS_USER_CONTENT_MANAGER (manager), NULL);
    self = g_object_new (XANH_TYPE_EXTERNAL_NAVIGATION_BRIDGE, NULL);
    self->manager = g_object_ref (manager);
    if (!webkit_user_content_manager_register_script_message_handler (
            manager, XANH_EXTERNAL_HANDLER, XANH_EXTERNAL_WORLD)) {
        g_set_error_literal (
            error, G_IO_ERROR, G_IO_ERROR_EXISTS,
            "The isolated external-navigation message handler is already registered");
        g_object_unref (self);
        return NULL;
    }
    self->handler_registered = TRUE;
    self->message_signal = g_signal_connect (
        manager, "script-message-received::" XANH_EXTERNAL_HANDLER,
        G_CALLBACK (message_received), self);
    self->script = webkit_user_script_new_for_world (
        bootstrap_source,
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        XANH_EXTERNAL_WORLD,
        allow_list,
        NULL);
    webkit_user_content_manager_add_script (manager, self->script);
    return self;
}
