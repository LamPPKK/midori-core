/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "sync-host.h"

int
main (int argc, char **argv)
{
    g_autoptr (XanhSyncHost) host = NULL;
    g_autofree gchar *domain = NULL;

    g_setenv ("XANH_FXA_CLIENT_ID", "xanh-host-contract", TRUE);
    g_setenv ("XANH_FXA_ACCOUNTS_URL", "https://accounts.example.test", TRUE);
    g_setenv ("XANH_FXA_TOKEN_SERVER_URL", "https://sync.example.test/token", TRUE);
    g_unsetenv ("XANH_FXA_PRODUCTION_APPROVED");

    host = xanh_sync_host_new ("/tmp/xanh-sync-host-production-test");
    g_assert_nonnull (host);
    g_assert_true (xanh_sync_host_is_configured (host));
    domain = xanh_sync_host_dup_account_domain (host);
    g_assert_cmpstr (domain, ==, "accounts.example.test");
    g_assert_true (xanh_sync_host_is_redirect_uri (
        host, "xanh-browser://accounts/oauth?code=code&state=state"));
    return 0;
}
