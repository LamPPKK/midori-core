/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "sync-host.h"
#include <glib/gstdio.h>

static void
test_redirect_policy (void)
{
    g_autoptr (XanhSyncHost) host = xanh_sync_host_new ("/tmp/xanh-sync-host-test");

    g_assert_true (xanh_sync_host_is_redirect_uri (
        host, "xanh-browser://accounts/oauth?code=code&state=state"));
    g_assert_false (xanh_sync_host_is_redirect_uri (
        host, "http://accounts/oauth?code=code&state=state"));
    g_assert_false (xanh_sync_host_is_redirect_uri (
        host, "xanh-browser://attacker/oauth?code=code&state=state"));
    g_assert_false (xanh_sync_host_is_redirect_uri (
        host, "xanh-browser://accounts/other?code=code&state=state"));
    g_assert_false (xanh_sync_host_is_redirect_uri (
        host, "xanh-browser://user@accounts/oauth?code=code&state=state"));
    g_assert_false (xanh_sync_host_is_redirect_uri (
        host, "xanh-browser://accounts:444/oauth?code=code&state=state"));
    g_assert_false (xanh_sync_host_is_redirect_uri (
        host, "xanh-browser://accounts/oauth?code=code&state=state#fragment"));

    g_assert_true (xanh_sync_host_validate_redirect_uri (
        host, "xanh-browser://accounts/oauth?code=code&state=state", NULL));
    g_assert_false (xanh_sync_host_validate_redirect_uri (
        host, "xanh-browser://accounts/oauth?code=one&code=two&state=state", NULL));
    g_assert_false (xanh_sync_host_validate_redirect_uri (
        host, "xanh-browser://accounts/oauth?code=code", NULL));
    g_assert_false (xanh_sync_host_validate_redirect_uri (
        host, "xanh-browser://accounts/oauth?state=state", NULL));
}

static void
unavailable_initialized (GObject      *source,
                         GAsyncResult *result,
                         gpointer      user_data)
{
    GMainLoop *loop = user_data;
    g_autoptr (GError) error = NULL;

    g_assert_false (xanh_sync_host_initialize_finish (
        XANH_SYNC_HOST (source), result, &error));
    g_assert_error (error, XANH_SYNC_HOST_ERROR,
                    XANH_SYNC_HOST_ERROR_UNAVAILABLE);
    g_main_loop_quit (loop);
}

static void
test_disabled_build_fails_closed (void)
{
    g_autoptr (XanhSyncHost) host = xanh_sync_host_new ("/tmp/xanh-sync-host-test");
    g_autoptr (GMainLoop) loop = g_main_loop_new (NULL, FALSE);

    g_assert_false (xanh_sync_host_is_configured (host));
    g_assert_false (xanh_sync_host_is_ready (host));
    g_assert_cmpint (xanh_sync_host_account_state (host), ==, 0);
    xanh_sync_host_initialize_async (
        host, NULL, unavailable_initialized, loop);
    g_main_loop_run (loop);
}

static void
unavailable_data_finished (GObject      *source,
                           GAsyncResult *result,
                           gpointer      user_data)
{
    GMainLoop *loop = user_data;
    g_autoptr (GError) error = NULL;
    g_autofree gchar *value = xanh_sync_host_import_legacy_bookmarks_finish (
        XANH_SYNC_HOST (source), result, &error);

    g_assert_null (value);
    g_assert_error (error, XANH_SYNC_HOST_ERROR,
                    XANH_SYNC_HOST_ERROR_UNAVAILABLE);
    g_main_loop_quit (loop);
}

static void
unavailable_clear_history_finished (GObject      *source,
                                    GAsyncResult *result,
                                    gpointer      user_data)
{
    GMainLoop *loop = user_data;
    g_autoptr (GError) error = NULL;

    g_assert_false (xanh_sync_host_clear_history_finish (
        XANH_SYNC_HOST (source), result, &error));
    g_assert_error (error, XANH_SYNC_HOST_ERROR,
                    XANH_SYNC_HOST_ERROR_UNAVAILABLE);
    g_main_loop_quit (loop);
}

static void
test_disabled_data_bridge_fails_closed (void)
{
    g_autoptr (XanhSyncHost) host = xanh_sync_host_new ("/tmp/xanh-sync-host-test");
    g_autoptr (GMainLoop) loop = g_main_loop_new (NULL, FALSE);

    xanh_sync_host_import_legacy_bookmarks_async (
        host, "[]", NULL, unavailable_data_finished, loop);
    g_main_loop_run (loop);
    xanh_sync_host_clear_history_async (
        host, NULL, unavailable_clear_history_finished, loop);
    g_main_loop_run (loop);
}

static void
test_schedule_policy (void)
{
    g_autoptr (XanhSyncHost) host = xanh_sync_host_new ("/tmp/xanh-sync-host-test");

    xanh_sync_host_mark_local_change (host, 100);
    /* A disconnected host never becomes due, even after debounce. */
    g_assert_false (xanh_sync_host_sync_due (
        host, XANH_SYNC_REASON_LOCAL_CHANGE, 130));
    g_assert_false (xanh_sync_host_sync_due (
        host, XANH_SYNC_REASON_MANUAL, 130));
}

static void
test_durable_local_marker (void)
{
    g_autofree gchar *directory = g_dir_make_tmp ("xanh-sync-marker-XXXXXX", NULL);
    g_autofree gchar *path = NULL;
    g_autofree gchar *contents = NULL;
    g_autoptr (GError) error = NULL;
    GStatBuf stat_buffer;

    g_assert_nonnull (directory);
    path = g_build_filename (directory, "remove-pending", NULL);
    g_assert_true (xanh_sync_write_durable_marker (path, &error));
    g_assert_no_error (error);
    g_assert_true (g_file_get_contents (path, &contents, NULL, &error));
    g_assert_no_error (error);
    g_assert_cmpstr (contents, ==, "pending\n");
    g_assert_cmpint (g_stat (path, &stat_buffer), ==, 0);
    g_assert_cmpuint (stat_buffer.st_mode & 0777, ==, 0600);
    g_assert_true (xanh_sync_remove_durable_marker (path, &error));
    g_assert_no_error (error);
    g_assert_false (g_file_test (path, G_FILE_TEST_EXISTS));
    g_assert_true (xanh_sync_remove_durable_marker (path, &error));
    g_assert_no_error (error);
    g_assert_cmpint (g_rmdir (directory), ==, 0);
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/sync-host/redirect-policy", test_redirect_policy);
    g_test_add_func ("/sync-host/disabled-fails-closed", test_disabled_build_fails_closed);
    g_test_add_func ("/sync-host/disabled-data-bridge", test_disabled_data_bridge_fails_closed);
    g_test_add_func ("/sync-host/disconnected-not-due", test_schedule_policy);
    g_test_add_func ("/sync-host/durable-local-marker", test_durable_local_marker);
    return g_test_run ();
}
