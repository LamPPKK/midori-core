/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "credential-bridge.h"

#include <json-glib/json-glib.h>

#define XANH_CREDENTIAL_WORLD "io.github.lamppkk.xanhbrowser.credentials"
#define XANH_CREDENTIAL_HANDLER "xanhCredentialBridge"
#define XANH_CREDENTIAL_MESSAGE_LIMIT 4096
#define XANH_CREDENTIAL_URL_LIMIT 8192
#define XANH_CREDENTIAL_TOKEN_LIMIT 128

struct _XanhCredentialBridge {
    GObject parent_instance;
    WebKitUserContentManager *manager;
    WebKitWebView *web_view;
    WebKitUserScript *script;
    gulong message_signal;
    gulong load_signal;
    gboolean handler_registered;
    gchar *tab_id;
    gchar *navigation_nonce;
    gchar *origin;
    gchar *request_id;
    gchar *request_document_url;
    gboolean fill_running;
};

G_DEFINE_TYPE (XanhCredentialBridge, xanh_credential_bridge, G_TYPE_OBJECT)

enum {
    REQUEST,
    LAST_SIGNAL
};

static guint signals[LAST_SIGNAL];

static const gchar bootstrap_template[] =
    "(() => {\n"
    "  if (window.top !== window || location.protocol !== 'https:') return;\n"
    "  const handler = window.webkit?.messageHandlers?.xanhCredentialBridge;\n"
    "  if (!handler || !globalThis.crypto?.randomUUID) return;\n"
    "  const tabId = '%s';\n"
    "  const navigationNonce = crypto.randomUUID();\n"
    "  let requestedFor = null;\n"
    "  let requestId = null;\n"
    "  let userGestureDeadline = 0;\n"
    "  const post = messageType => {\n"
    "    const value = { tabId, navigationNonce, messageType,\n"
    "      documentUrl: location.href, origin: location.origin };\n"
    "    if (requestId) value.requestId = requestId;\n"
    "    handler.postMessage(JSON.stringify(value));\n"
    "  };\n"
    "  const requestCredential = target => {\n"
    "    if (!(target instanceof HTMLInputElement) || target.type !== 'password') return;\n"
    "    if (performance.now() > userGestureDeadline) return;\n"
    "    userGestureDeadline = 0;\n"
    "    requestedFor = target;\n"
    "    requestId = crypto.randomUUID();\n"
    "    post('credential-request');\n"
    "  };\n"
    "  globalThis.__xanhBrowserFillCredential = (\n"
    "    expectedRequestId, username, passwordValue, expectedNonce, expectedOrigin\n"
    "  ) => {\n"
    "    if (requestId !== expectedRequestId || navigationNonce !== expectedNonce ||\n"
    "        location.origin !== expectedOrigin) return false;\n"
    "    const password = requestedFor;\n"
    "    if (!(password instanceof HTMLInputElement) || !password.isConnected) return false;\n"
    "    const root = password.form || document;\n"
    "    const user = root.querySelector(\n"
    "      'input[autocomplete=\"username\"], input[type=\"email\"], input[type=\"text\"]'\n"
    "    );\n"
    "    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;\n"
    "    if (typeof setter !== 'function') return false;\n"
    "    if (user instanceof HTMLInputElement) {\n"
    "      setter.call(user, username || '');\n"
    "      user.dispatchEvent(new Event('input', { bubbles: true }));\n"
    "      user.dispatchEvent(new Event('change', { bubbles: true }));\n"
    "    }\n"
    "    setter.call(password, passwordValue || '');\n"
    "    password.dispatchEvent(new Event('input', { bubbles: true }));\n"
    "    password.dispatchEvent(new Event('change', { bubbles: true }));\n"
    "    requestedFor = null;\n"
    "    requestId = null;\n"
    "    return true;\n"
    "  };\n"
    "  post('credential-ready');\n"
    "  document.addEventListener('pointerdown', event => {\n"
    "    if (!event.isTrusted) return;\n"
    "    userGestureDeadline = performance.now() + 1500;\n"
    "    requestCredential(event.target);\n"
    "  }, true);\n"
    "  document.addEventListener('keydown', event => {\n"
    "    if (!event.isTrusted) return;\n"
    "    userGestureDeadline = performance.now() + 1500;\n"
    "    requestCredential(event.target);\n"
    "  }, true);\n"
    "})();";

static void
clear_request (XanhCredentialBridge *self)
{
    g_clear_pointer (&self->request_id, g_free);
    g_clear_pointer (&self->request_document_url, g_free);
}

static void
clear_navigation (XanhCredentialBridge *self)
{
    clear_request (self);
    g_clear_pointer (&self->navigation_nonce, g_free);
    g_clear_pointer (&self->origin, g_free);
}

static gboolean
valid_token (const gchar *value)
{
    gsize length;

    if (value == NULL || !g_utf8_validate (value, -1, NULL))
        return FALSE;
    length = strlen (value);
    if (length == 0 || length > XANH_CREDENTIAL_TOKEN_LIMIT)
        return FALSE;
    for (gsize index = 0; index < length; index++) {
        if (!(g_ascii_isalnum (value[index]) || value[index] == '-'))
            return FALSE;
    }
    return TRUE;
}

static gint
normalized_port (GUri *uri)
{
    gint port = g_uri_get_port (uri);
    return port == -1 ? 443 : port;
}

gboolean
xanh_credential_bridge_context_is_safe (const gchar *document_url,
                                        const gchar *origin)
{
    g_autoptr (GUri) document = NULL;
    g_autoptr (GUri) top = NULL;
    const gchar *path;

    if (document_url == NULL || origin == NULL ||
        strlen (document_url) == 0 || strlen (document_url) > XANH_CREDENTIAL_URL_LIMIT ||
        strlen (origin) == 0 || strlen (origin) > XANH_CREDENTIAL_URL_LIMIT ||
        !g_utf8_validate (document_url, -1, NULL) || !g_utf8_validate (origin, -1, NULL))
        return FALSE;
    document = g_uri_parse (document_url, G_URI_FLAGS_NONE, NULL);
    top = g_uri_parse (origin, G_URI_FLAGS_NONE, NULL);
    if (document == NULL || top == NULL ||
        g_strcmp0 (g_uri_get_scheme (document), "https") != 0 ||
        g_strcmp0 (g_uri_get_scheme (top), "https") != 0 ||
        g_uri_get_host (document) == NULL || g_uri_get_host (top) == NULL ||
        g_uri_get_userinfo (document) != NULL || g_uri_get_userinfo (top) != NULL ||
        g_uri_get_query (top) != NULL || g_uri_get_fragment (top) != NULL)
        return FALSE;
    path = g_uri_get_path (top);
    if (path != NULL && *path != '\0' && g_strcmp0 (path, "/") != 0)
        return FALSE;
    return g_ascii_strcasecmp (
               g_uri_get_host (document), g_uri_get_host (top)) == 0 &&
        normalized_port (document) == normalized_port (top);
}

static const gchar *
required_string (JsonObject  *object,
                 const gchar *member)
{
    JsonNode *node;

    if (!json_object_has_member (object, member))
        return NULL;
    node = json_object_get_member (object, member);
    if (node == NULL || json_node_get_value_type (node) != G_TYPE_STRING)
        return NULL;
    return json_node_get_string (node);
}

static gboolean
current_document_matches (XanhCredentialBridge *self,
                          const gchar          *document_url,
                          const gchar          *origin)
{
    const gchar *current = webkit_web_view_get_uri (self->web_view);
    return current != NULL && g_strcmp0 (current, document_url) == 0 &&
        xanh_credential_bridge_context_is_safe (document_url, origin);
}

static void
message_received (WebKitUserContentManager *manager,
                  JSCValue                 *value,
                  gpointer                  user_data)
{
    XanhCredentialBridge *self = XANH_CREDENTIAL_BRIDGE (user_data);
    g_autofree gchar *message = NULL;
    g_autoptr (JsonParser) parser = NULL;
    JsonNode *root;
    JsonObject *object;
    const gchar *tab_id;
    const gchar *nonce;
    const gchar *message_type;
    const gchar *document_url;
    const gchar *origin;
    const gchar *request_id;
    guint expected_members;

    (void) manager;
    if (!jsc_value_is_string (value))
        return;
    message = jsc_value_to_string (value);
    if (message == NULL || strlen (message) > XANH_CREDENTIAL_MESSAGE_LIMIT ||
        !g_utf8_validate (message, -1, NULL))
        return;
    parser = json_parser_new ();
    if (!json_parser_load_from_data (parser, message, -1, NULL))
        return;
    root = json_parser_get_root (parser);
    if (root == NULL || !JSON_NODE_HOLDS_OBJECT (root))
        return;
    object = json_node_get_object (root);
    tab_id = required_string (object, "tabId");
    nonce = required_string (object, "navigationNonce");
    message_type = required_string (object, "messageType");
    document_url = required_string (object, "documentUrl");
    origin = required_string (object, "origin");
    if (g_strcmp0 (tab_id, self->tab_id) != 0 || !valid_token (nonce) ||
        message_type == NULL || !current_document_matches (self, document_url, origin))
        return;

    if (g_strcmp0 (message_type, "credential-ready") == 0) {
        expected_members = 5;
        if (json_object_get_size (object) != expected_members)
            return;
        clear_navigation (self);
        self->navigation_nonce = g_strdup (nonce);
        self->origin = g_strdup (origin);
        return;
    }
    if (g_strcmp0 (message_type, "credential-request") != 0 ||
        json_object_get_size (object) != 6 || self->fill_running ||
        self->request_id != NULL ||
        g_strcmp0 (nonce, self->navigation_nonce) != 0 ||
        g_strcmp0 (origin, self->origin) != 0)
        return;
    request_id = required_string (object, "requestId");
    if (!valid_token (request_id))
        return;
    self->request_id = g_strdup (request_id);
    self->request_document_url = g_strdup (document_url);
    g_signal_emit (self, signals[REQUEST], 0,
                   request_id, nonce, document_url, origin);
}

static void
load_changed (WebKitWebView  *web_view,
              WebKitLoadEvent event,
              gpointer        user_data)
{
    (void) web_view;
    if (event == WEBKIT_LOAD_STARTED)
        clear_navigation (XANH_CREDENTIAL_BRIDGE (user_data));
}

static void
fill_finished (GObject      *source,
               GAsyncResult *result,
               gpointer      user_data)
{
    GTask *task = G_TASK (user_data);
    XanhCredentialBridge *self = g_task_get_source_object (task);
    g_autoptr (GError) error = NULL;
    g_autoptr (JSCValue) value = NULL;
    gboolean filled = FALSE;

    value = webkit_web_view_call_async_javascript_function_finish (
        WEBKIT_WEB_VIEW (source), result, &error);
    if (value != NULL && jsc_value_is_boolean (value))
        filled = jsc_value_to_boolean (value);
    self->fill_running = FALSE;
    clear_request (self);
    if (error != NULL) {
        g_task_return_error (task, g_steal_pointer (&error));
    } else if (!filled) {
        g_task_return_new_error (
            task, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
            "The credential target changed before it could be filled");
    } else {
        g_task_return_boolean (task, TRUE);
    }
    g_object_unref (task);
}

static void
xanh_credential_bridge_dispose (GObject *object)
{
    XanhCredentialBridge *self = XANH_CREDENTIAL_BRIDGE (object);

    clear_navigation (self);
    if (self->manager != NULL) {
        if (self->message_signal != 0) {
            g_signal_handler_disconnect (self->manager, self->message_signal);
            self->message_signal = 0;
        }
        if (self->handler_registered) {
            webkit_user_content_manager_unregister_script_message_handler (
                self->manager, XANH_CREDENTIAL_HANDLER, XANH_CREDENTIAL_WORLD);
            self->handler_registered = FALSE;
        }
        if (self->script != NULL)
            webkit_user_content_manager_remove_script (self->manager, self->script);
    }
    if (self->web_view != NULL && self->load_signal != 0) {
        g_signal_handler_disconnect (self->web_view, self->load_signal);
        self->load_signal = 0;
    }
    g_clear_pointer (&self->script, webkit_user_script_unref);
    g_clear_object (&self->manager);
    g_clear_object (&self->web_view);
    g_clear_pointer (&self->tab_id, g_free);
    G_OBJECT_CLASS (xanh_credential_bridge_parent_class)->dispose (object);
}

static void
xanh_credential_bridge_class_init (XanhCredentialBridgeClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);
    object_class->dispose = xanh_credential_bridge_dispose;
    signals[REQUEST] = g_signal_new (
        "request", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST,
        0, NULL, NULL, NULL, G_TYPE_NONE, 4,
        G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING);
}

static void
xanh_credential_bridge_init (XanhCredentialBridge *self)
{
    (void) self;
}

XanhCredentialBridge *
xanh_credential_bridge_new (WebKitUserContentManager *manager,
                            WebKitWebView            *web_view,
                            GError                  **error)
{
    g_autofree gchar *source = NULL;
    static const gchar *allow_list[] = { "https://*/*", NULL };
    XanhCredentialBridge *self;

    g_return_val_if_fail (WEBKIT_IS_USER_CONTENT_MANAGER (manager), NULL);
    g_return_val_if_fail (WEBKIT_IS_WEB_VIEW (web_view), NULL);
    self = g_object_new (XANH_TYPE_CREDENTIAL_BRIDGE, NULL);
    self->manager = g_object_ref (manager);
    self->web_view = g_object_ref (web_view);
    self->tab_id = g_uuid_string_random ();
    self->message_signal = g_signal_connect (
        manager, "script-message-received::" XANH_CREDENTIAL_HANDLER,
        G_CALLBACK (message_received), self);
    if (!webkit_user_content_manager_register_script_message_handler (
            manager, XANH_CREDENTIAL_HANDLER, XANH_CREDENTIAL_WORLD)) {
        g_set_error_literal (
            error, G_IO_ERROR, G_IO_ERROR_EXISTS,
            "The isolated credential message handler is already registered");
        g_object_unref (self);
        return NULL;
    }
    self->handler_registered = TRUE;
    source = g_strdup_printf (bootstrap_template, self->tab_id);
    self->script = webkit_user_script_new_for_world (
        source,
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        XANH_CREDENTIAL_WORLD,
        allow_list,
        NULL);
    webkit_user_content_manager_add_script (manager, self->script);
    self->load_signal = g_signal_connect (
        web_view, "load-changed", G_CALLBACK (load_changed), self);
    return self;
}

gboolean
xanh_credential_bridge_request_is_current (XanhCredentialBridge *self,
                                           const gchar          *request_id,
                                           const gchar          *navigation_nonce,
                                           const gchar          *document_url,
                                           const gchar          *origin)
{
    g_return_val_if_fail (XANH_IS_CREDENTIAL_BRIDGE (self), FALSE);
    return !self->fill_running &&
        g_strcmp0 (self->request_id, request_id) == 0 &&
        g_strcmp0 (self->navigation_nonce, navigation_nonce) == 0 &&
        g_strcmp0 (self->request_document_url, document_url) == 0 &&
        g_strcmp0 (self->origin, origin) == 0 &&
        current_document_matches (self, document_url, origin);
}

void
xanh_credential_bridge_cancel_request (XanhCredentialBridge *self,
                                       const gchar          *request_id)
{
    g_return_if_fail (XANH_IS_CREDENTIAL_BRIDGE (self));
    if (request_id == NULL || g_strcmp0 (self->request_id, request_id) == 0)
        clear_request (self);
}

void
xanh_credential_bridge_fill_async (XanhCredentialBridge *self,
                                   const gchar          *request_id,
                                   const gchar          *navigation_nonce,
                                   const gchar          *document_url,
                                   const gchar          *origin,
                                   const gchar          *username,
                                   const gchar          *password,
                                   GCancellable         *cancellable,
                                   GAsyncReadyCallback   callback,
                                   gpointer              user_data)
{
    static const gchar body[] =
        "return globalThis.__xanhBrowserFillCredential?.("
        "requestId, username, password, navigationNonce, expectedOrigin) === true;";
    GVariantBuilder arguments;
    g_autoptr (GVariant) argument_values = NULL;
    GTask *task;

    g_return_if_fail (XANH_IS_CREDENTIAL_BRIDGE (self));
    task = g_task_new (self, cancellable, callback, user_data);
    if (!xanh_credential_bridge_request_is_current (
            self, request_id, navigation_nonce, document_url, origin)) {
        g_task_return_new_error (
            task, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
            "The credential request no longer matches this navigation");
        g_object_unref (task);
        return;
    }
    if (username == NULL || password == NULL ||
        strlen (username) > 1024 || strlen (password) > 4096 ||
        !g_utf8_validate (username, -1, NULL) || !g_utf8_validate (password, -1, NULL)) {
        clear_request (self);
        g_task_return_new_error (
            task, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
            "The selected credential exceeds the safe bridge bounds");
        g_object_unref (task);
        return;
    }
    self->fill_running = TRUE;
    g_variant_builder_init (&arguments, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add (&arguments, "{sv}", "requestId",
                           g_variant_new_string (request_id));
    g_variant_builder_add (&arguments, "{sv}", "username",
                           g_variant_new_string (username));
    g_variant_builder_add (&arguments, "{sv}", "password",
                           g_variant_new_string (password));
    g_variant_builder_add (&arguments, "{sv}", "navigationNonce",
                           g_variant_new_string (navigation_nonce));
    g_variant_builder_add (&arguments, "{sv}", "expectedOrigin",
                           g_variant_new_string (origin));
    argument_values = g_variant_ref_sink (g_variant_builder_end (&arguments));
    webkit_web_view_call_async_javascript_function (
        self->web_view, body, -1, argument_values,
        XANH_CREDENTIAL_WORLD, "xanh-browser-credential-bridge.js",
        cancellable, fill_finished, task);
}

gboolean
xanh_credential_bridge_fill_finish (XanhCredentialBridge *self,
                                    GAsyncResult         *result,
                                    GError              **error)
{
    g_return_val_if_fail (g_task_is_valid (result, self), FALSE);
    return g_task_propagate_boolean (G_TASK (result), error);
}
