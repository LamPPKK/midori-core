/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_normalized_domains () {
    string[] domains = Xanh.AdblockSource.normalized_domains (
        " *.Ads.Example,ads.example,good-domain.test,.invalid,bad_domain.test, ");
    assert (domains.length == 2);
    assert (domains[0] == "ads.example");
    assert (domains[1] == "good-domain.test");
}

void test_native_filter_list () {
    try {
        string source = Xanh.AdblockSource.native_filter_list (
            "! configured rules\n||configured.example^",
            "ads.example,*.metrics.example",
            "allowed.example");
        assert (source.has_prefix (
            "! configured rules\n||configured.example^\n"));
        assert (source.contains ("||ads.example^\n"));
        assert (source.contains ("||metrics.example^\n"));
        assert (source.contains ("@@*$domain=allowed.example\n"));

        string canonical = Xanh.AdblockSource.native_filter_list (
            "||ads.example^\n||configured.example^\n",
            "ads.example,metrics.example", "");
        assert (canonical ==
            "||ads.example^\n||configured.example^\n||metrics.example^\n");
    } catch (Error error) {
        Test.fail_printf ("Unexpected source error: %s", error.message);
    }
}

void test_legacy_filter_json () {
    string json = Xanh.AdblockSource.legacy_webkit_json (
        { "ads.example", "metrics.example" }, { "allowed.example" });
    assert (json ==
        "[{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*ads.example\",\"*metrics.example\"],\"unless-domain\":[\"*allowed.example\"]},\"action\":{\"type\":\"block\"}}]");
}

void test_native_filter_list_limit () {
    string oversized = string.nfill (
        Xanh.AdblockSource.MAX_FILTER_LIST_BYTES + 1, 'a');
    try {
        Xanh.AdblockSource.native_filter_list (oversized, "", "");
        Test.fail_printf ("Oversized source was accepted");
    } catch (Xanh.AdblockSourceError error) {
        assert (error is Xanh.AdblockSourceError.TOO_LARGE);
    }

    string long_line = string.nfill (
        Xanh.AdblockSource.MAX_FILTER_LINE_BYTES + 1, 'a');
    try {
        Xanh.AdblockSource.native_filter_list (long_line, "", "");
        Test.fail_printf ("Oversized source line was accepted");
    } catch (Xanh.AdblockSourceError error) {
        assert (error is Xanh.AdblockSourceError.TOO_LARGE);
    }
}

void test_domain_list_bounds () {
    string oversized = string.nfill (
        Xanh.AdblockSource.MAX_DOMAIN_LIST_BYTES + 1, 'a');
    assert (Xanh.AdblockSource.normalized_domains (oversized).length == 0);

    string too_many = string.nfill (Xanh.AdblockSource.MAX_DOMAINS, ',');
    try {
        Xanh.AdblockSource.checked_normalized_domains (too_many);
        Test.fail_printf ("Excessive domain count was accepted");
    } catch (Xanh.AdblockSourceError error) {
        assert (error is Xanh.AdblockSourceError.TOO_LARGE);
    }

    string long_domain = string.nfill (
        Xanh.AdblockSource.MAX_DOMAIN_BYTES + 1, 'a');
    assert (Xanh.AdblockSource.normalized_domains (long_domain).length == 0);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/adblock-source/domains", test_normalized_domains);
    Test.add_func ("/adblock-source/native", test_native_filter_list);
    Test.add_func ("/adblock-source/legacy", test_legacy_filter_json);
    Test.add_func ("/adblock-source/limit", test_native_filter_list_limit);
    Test.add_func ("/adblock-source/domain-bounds", test_domain_list_bounds);
    return Test.run ();
}
