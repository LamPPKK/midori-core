/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "external-navigation-data.h"

static void
test_bounded_exact_message (void)
{
    g_autofree gchar *external_uri = NULL;
    g_autofree gchar *document_uri = NULL;
    g_autofree gchar *oversized = NULL;
    g_autofree gchar *repeated = NULL;

    g_assert_true (xanh_external_navigation_parse_message (
        "{\"externalUrl\":\"mailto:user@example.com\","
        "\"documentUrl\":\"https://example.com/page\"}",
        &external_uri, &document_uri));
    g_assert_cmpstr (external_uri, ==, "mailto:user@example.com");
    g_assert_cmpstr (document_uri, ==, "https://example.com/page");
    g_clear_pointer (&external_uri, g_free);
    g_clear_pointer (&document_uri, g_free);

    g_assert_false (xanh_external_navigation_parse_message (
        "{\"externalUrl\":\"tel:+84123\"}", &external_uri, &document_uri));
    g_assert_false (xanh_external_navigation_parse_message (
        "{\"externalUrl\":42,\"documentUrl\":\"https://example.com/\"}",
        &external_uri, &document_uri));
    g_assert_false (xanh_external_navigation_parse_message (
        "{\"externalUrl\":\"tel:+84123\","
        "\"documentUrl\":\"https://example.com/\",\"extra\":true}",
        &external_uri, &document_uri));
    g_assert_false (xanh_external_navigation_parse_message (
        "not-json", &external_uri, &document_uri));
    g_assert_false (xanh_external_navigation_parse_message (
        "{\"externalUrl\":\"tel:+84\\u0000123\","
        "\"documentUrl\":\"https://example.com/\"}",
        &external_uri, &document_uri));

    repeated = g_strnfill (2049, 'a');
    oversized = g_strdup_printf (
        "{\"externalUrl\":\"mailto:%s\","
        "\"documentUrl\":\"https://example.com/\"}",
        repeated);
    g_assert_false (xanh_external_navigation_parse_message (
        oversized, &external_uri, &document_uri));
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func (
        "/external-navigation-bridge/bounded-exact-message",
        test_bounded_exact_message);
    return g_test_run ();
}
