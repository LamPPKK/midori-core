/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "adblock-host.h"

#include <json-glib/json-glib.h>
#include <string.h>

typedef struct {
    GMainLoop *loop;
    GBytes *rules;
    GError *error;
} CompileResult;

static void
compile_finished (GObject      *source_object,
                  GAsyncResult *result,
                  gpointer      user_data)
{
    CompileResult *compile = user_data;

    (void) source_object;
    compile->rules = xanh_adblock_host_compile_finish (result, &compile->error);
    g_main_loop_quit (compile->loop);
}

static CompileResult
compile_sync_for_test (const gchar *filter_list)
{
    CompileResult result = { 0 };

    result.loop = g_main_loop_new (NULL, FALSE);
    xanh_adblock_host_compile_async (
        filter_list, NULL, compile_finished, &result);
    g_main_loop_run (result.loop);
    g_clear_pointer (&result.loop, g_main_loop_unref);
    return result;
}

static void
test_limits (void)
{
    g_assert_cmpuint (XANH_ADBLOCK_HOST_MAX_FILTER_LIST_BYTES, ==,
                      (gsize) 16 * 1024 * 1024);
    g_assert_cmpuint (XANH_ADBLOCK_HOST_MAX_CONTENT_BLOCKER_BYTES, ==,
                      (gsize) 64 * 1024 * 1024);
    g_assert_cmpint (XANH_ADBLOCK_HOST_MAX_PENDING_COMPILATIONS, ==, 2);
}

static void
test_availability_contract (void)
{
#ifdef XANH_ENABLE_ADBLOCK_RUST
    g_assert_true (xanh_adblock_host_is_available ());
#else
    g_assert_false (xanh_adblock_host_is_available ());
#endif
}

static void
test_compile_contract (void)
{
    CompileResult result = compile_sync_for_test (
        "||ads.example^\n@@*$domain=allowed.example\n");

#ifdef XANH_ENABLE_ADBLOCK_RUST
    g_autoptr (JsonParser) parser = json_parser_new ();
    gconstpointer data;
    gsize length;

    g_assert_no_error (result.error);
    g_assert_nonnull (result.rules);
    data = g_bytes_get_data (result.rules, &length);
    g_assert_cmpuint (length, >, 2);
    g_assert_true (json_parser_load_from_data (parser, data, length, NULL));
    g_assert_true (JSON_NODE_HOLDS_ARRAY (json_parser_get_root (parser)));
#else
    g_assert_null (result.rules);
    g_assert_error (result.error, XANH_ADBLOCK_HOST_ERROR,
                    XANH_ADBLOCK_HOST_ERROR_UNAVAILABLE);
#endif

    g_clear_pointer (&result.rules, g_bytes_unref);
    g_clear_error (&result.error);
}

#ifdef XANH_ENABLE_ADBLOCK_RUST
static void
test_invalid_input (void)
{
    CompileResult result = compile_sync_for_test ("");
    g_autofree gchar *oversized = NULL;

    g_assert_null (result.rules);
    g_assert_error (result.error, XANH_ADBLOCK_HOST_ERROR,
                    XANH_ADBLOCK_HOST_ERROR_INVALID_INPUT);
    g_clear_error (&result.error);

    oversized = g_malloc (XANH_ADBLOCK_HOST_MAX_FILTER_LIST_BYTES + 2);
    memset (oversized, 'a', XANH_ADBLOCK_HOST_MAX_FILTER_LIST_BYTES + 1);
    oversized[XANH_ADBLOCK_HOST_MAX_FILTER_LIST_BYTES + 1] = '\0';
    result = compile_sync_for_test (oversized);
    g_assert_null (result.rules);
    g_assert_error (result.error, XANH_ADBLOCK_HOST_ERROR,
                    XANH_ADBLOCK_HOST_ERROR_INVALID_INPUT);
    g_clear_error (&result.error);
}

static void
test_empty_compilation_fails_closed (void)
{
    CompileResult result = compile_sync_for_test ("! comments only\n");

    g_assert_null (result.rules);
    g_assert_error (result.error, XANH_ADBLOCK_HOST_ERROR,
                    XANH_ADBLOCK_HOST_ERROR_CORE);
    g_clear_error (&result.error);
}
#endif

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/adblock-host/limits", test_limits);
    g_test_add_func ("/adblock-host/availability", test_availability_contract);
    g_test_add_func ("/adblock-host/compile", test_compile_contract);
#ifdef XANH_ENABLE_ADBLOCK_RUST
    g_test_add_func ("/adblock-host/invalid-input", test_invalid_input);
    g_test_add_func ("/adblock-host/empty-output", test_empty_compilation_fails_closed);
#endif
    return g_test_run ();
}
