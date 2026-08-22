/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "credential-bridge.h"

static void
test_exact_https_top_frame_policy (void)
{
    g_assert_true (xanh_credential_bridge_context_is_safe (
        "https://example.org/login?from=browser#password",
        "https://example.org"));
    g_assert_true (xanh_credential_bridge_context_is_safe (
        "https://example.org:8443/login", "https://example.org:8443"));
    g_assert_false (xanh_credential_bridge_context_is_safe (
        "http://example.org/login", "http://example.org"));
    g_assert_false (xanh_credential_bridge_context_is_safe (
        "https://user@example.org/login", "https://example.org"));
    g_assert_false (xanh_credential_bridge_context_is_safe (
        "https://example.org/login", "https://other.example"));
    g_assert_false (xanh_credential_bridge_context_is_safe (
        "https://example.org/login", "https://example.org/path"));
    g_assert_false (xanh_credential_bridge_context_is_safe (
        "https://example.org/login", "https://example.org?query=1"));
    g_assert_false (xanh_credential_bridge_context_is_safe (
        "https://example.org:8443/login", "https://example.org"));
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func (
        "/credential-bridge/exact-https-top-frame",
        test_exact_https_top_frame_policy);
    return g_test_run ();
}
