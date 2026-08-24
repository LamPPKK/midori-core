/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "adblock-host.h"

#include <json-glib/json-glib.h>
#include <string.h>

#ifdef XANH_ENABLE_ADBLOCK_RUST
#include <xanh_adblock.h>
#endif

typedef struct {
    gchar *filter_list;
} AdblockCompileData;

static gint pending_compilations;

G_DEFINE_QUARK (xanh-adblock-host-error-quark, xanh_adblock_host_error)

static gboolean
reserve_compilation_slot (void)
{
    gint pending;

    do {
        pending = g_atomic_int_get (&pending_compilations);
        if (pending >= XANH_ADBLOCK_HOST_MAX_PENDING_COMPILATIONS)
            return FALSE;
    } while (!g_atomic_int_compare_and_exchange (
        &pending_compilations, pending, pending + 1));
    return TRUE;
}

static void
adblock_compile_data_free (AdblockCompileData *data)
{
    if (data == NULL)
        return;
    g_clear_pointer (&data->filter_list, g_free);
    g_free (data);
    g_atomic_int_add (&pending_compilations, -1);
}

#ifdef XANH_ENABLE_ADBLOCK_RUST
static gchar *
dup_core_error (void)
{
    gchar *core_error = xanh_adblock_last_error ();
    gchar *message = NULL;

    if (core_error != NULL) {
        gsize length = strnlen (core_error, 513);
        if (length <= 512 && g_utf8_validate (core_error, length, NULL))
            message = g_strndup (core_error, length);
        xanh_adblock_string_free (core_error);
    }
    return message != NULL ? message : g_strdup ("native compiler failed");
}

static void
compile_worker (GTask        *task,
                gpointer      source_object,
                gpointer      task_data,
                GCancellable *cancellable)
{
    AdblockCompileData *data = task_data;
    g_autoptr (JsonParser) parser = NULL;
    g_autoptr (GError) parse_error = NULL;
    g_autofree gchar *core_error = NULL;
    gchar *compiled;
    gsize length;
    JsonNode *root;

    (void) source_object;
    (void) cancellable;
    if (g_task_return_error_if_cancelled (task))
        return;

    compiled = xanh_adblock_compile_webkit_json (data->filter_list);
    if (compiled == NULL) {
        core_error = dup_core_error ();
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_CORE,
            "adblock-rust could not compile the filter list: %s", core_error);
        return;
    }

    length = strnlen (compiled, XANH_ADBLOCK_HOST_MAX_CONTENT_BLOCKER_BYTES + 1);
    if (length > XANH_ADBLOCK_HOST_MAX_CONTENT_BLOCKER_BYTES ||
            !g_utf8_validate (compiled, length, NULL)) {
        xanh_adblock_string_free (compiled);
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_INVALID_OUTPUT,
            "adblock-rust returned invalid or oversized content-blocking JSON");
        return;
    }

    parser = json_parser_new ();
    if (!json_parser_load_from_data (parser, compiled, length, &parse_error)) {
        xanh_adblock_string_free (compiled);
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_INVALID_OUTPUT,
            "adblock-rust returned malformed content-blocking JSON");
        return;
    }
    root = json_parser_get_root (parser);
    if (!JSON_NODE_HOLDS_ARRAY (root) ||
            json_array_get_length (json_node_get_array (root)) == 0) {
        xanh_adblock_string_free (compiled);
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_INVALID_OUTPUT,
            "adblock-rust returned empty or malformed content-blocking JSON");
        return;
    }

    if (g_task_return_error_if_cancelled (task)) {
        xanh_adblock_string_free (compiled);
        return;
    }
    g_task_return_pointer (task, g_bytes_new (compiled, length),
                           (GDestroyNotify) g_bytes_unref);
    xanh_adblock_string_free (compiled);
}
#endif

gboolean
xanh_adblock_host_is_available (void)
{
#ifdef XANH_ENABLE_ADBLOCK_RUST
    const gchar *version = xanh_adblock_core_version ();
    gsize length;

    if (version == NULL)
        return FALSE;
    length = strnlen (version, 65);
    return length < 65 &&
        g_strcmp0 (version, XANH_ADBLOCK_CORE_ABI_VERSION) == 0;
#else
    return FALSE;
#endif
}

void
xanh_adblock_host_compile_async (const gchar         *filter_list,
                                 GCancellable        *cancellable,
                                 GAsyncReadyCallback  callback,
                                 gpointer             user_data)
{
    g_autoptr (GTask) task = g_task_new (NULL, cancellable, callback, user_data);
    AdblockCompileData *data;
    gsize length;

    g_task_set_source_tag (task, xanh_adblock_host_compile_async);
#ifndef XANH_ENABLE_ADBLOCK_RUST
    g_task_return_new_error (
        task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_UNAVAILABLE,
        "adblock-rust support is not enabled in this build");
    return;
#endif

#ifdef XANH_ENABLE_ADBLOCK_RUST
    if (!xanh_adblock_host_is_available ()) {
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_UNAVAILABLE,
            "adblock-rust ABI version does not match this host");
        return;
    }
#endif

    if (filter_list == NULL) {
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_INVALID_INPUT,
            "the adblock filter list is required");
        return;
    }
    length = strnlen (filter_list, XANH_ADBLOCK_HOST_MAX_FILTER_LIST_BYTES + 1);
    if (length == 0 || length > XANH_ADBLOCK_HOST_MAX_FILTER_LIST_BYTES ||
            !g_utf8_validate (filter_list, length, NULL)) {
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_INVALID_INPUT,
            "the adblock filter list is empty, invalid UTF-8 or oversized");
        return;
    }
    if (!reserve_compilation_slot ()) {
        g_task_return_new_error (
            task, XANH_ADBLOCK_HOST_ERROR, XANH_ADBLOCK_HOST_ERROR_BUSY,
            "too many adblock filter compilations are pending");
        return;
    }

    data = g_new0 (AdblockCompileData, 1);
    data->filter_list = g_strndup (filter_list, length);
    g_task_set_task_data (task, data, (GDestroyNotify) adblock_compile_data_free);
#ifdef XANH_ENABLE_ADBLOCK_RUST
    g_task_run_in_thread (task, compile_worker);
#endif
}

GBytes *
xanh_adblock_host_compile_finish (GAsyncResult *result,
                                  GError      **error)
{
    g_return_val_if_fail (g_task_is_valid (result, NULL), NULL);
    g_return_val_if_fail (
        g_async_result_is_tagged (result, xanh_adblock_host_compile_async), NULL);
    return g_task_propagate_pointer (G_TASK (result), error);
}
