/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_addresses () {
    assert (Xanh.AddressResolver.resolve ("https://example.com") == "https://example.com");
    assert (Xanh.AddressResolver.resolve ("example.com") == "https://example.com");
    assert (Xanh.AddressResolver.resolve ("localhost:8080") == "https://localhost:8080");
    assert (Xanh.AddressResolver.resolve ("xanh browser").has_prefix ("https://duckduckgo.com/?q="));
    assert (Xanh.AddressResolver.resolve ("https://user:secret@example.com/") == "about:blank");
    assert (Xanh.AddressResolver.resolve ("javascript:alert(1)") == "about:blank");
    assert (Xanh.AddressResolver.resolve ("https://example.com/\r\n") == "about:blank");
    assert (Xanh.AddressResolver.resolve ("50% xanh", "https://example.com/%20?q=%s&literal=percent") ==
        "https://example.com/%20?q=50%25%20xanh&literal=percent");
}

void test_safe_web_uri_policy () {
    string prefix = "https://example.com/";
    assert (Xanh.AddressResolver.is_safe_web_uri ("https://example.com/path?q=x#fragment"));
    assert (Xanh.AddressResolver.is_safe_web_uri ("http://localhost:8080"));
    assert (Xanh.AddressResolver.is_safe_web_uri ("https://[2001:db8::1]/"));
    assert (Xanh.AddressResolver.is_safe_web_uri ("https://bücher.example/"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://user:secret@example.com/"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://foo_bar.example/"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://999.1.1.1/"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://example.com:70000/"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://example.com/%0d%0aheader"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://example.com/%00"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://example.com/%c2%80"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://example.com/%zz"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://example.com/a b"));
    assert (!Xanh.AddressResolver.is_safe_web_uri ("https://[1:2:3:4:5:6:7:8:]/"));
    assert (Xanh.AddressResolver.is_safe_web_uri (
        prefix + string.nfill (Xanh.AddressResolver.MAX_WEB_URI_BYTES - prefix.length, 'a')));
    assert (!Xanh.AddressResolver.is_safe_web_uri (
        prefix + string.nfill (Xanh.AddressResolver.MAX_WEB_URI_BYTES - prefix.length + 1, 'a')));
    assert (Xanh.AddressResolver.resolve (string.nfill (2049, 'a')) == "about:blank");
    assert (Xanh.AddressResolver.is_safe_secure_web_uri ("https://example.com/"));
    assert (!Xanh.AddressResolver.is_safe_secure_web_uri ("http://example.com/"));
    assert (Xanh.AddressResolver.is_safe_host_name ("bücher.example"));
    assert (!Xanh.AddressResolver.is_safe_host_name ("bad host"));
    assert (!Xanh.AddressResolver.is_safe_host_name (string.nfill (1025, 'a')));
}

void test_navigation_and_external_uri_policy () {
    assert (Xanh.AddressResolver.is_safe_navigation_uri ("about:blank"));
    assert (Xanh.AddressResolver.is_safe_navigation_uri ("HTTPS://example.com/"));
    assert (!Xanh.AddressResolver.is_safe_navigation_uri ("ABOUT:BLANK"));
    assert (!Xanh.AddressResolver.is_safe_navigation_uri ("about:blank?query"));
    assert (!Xanh.AddressResolver.is_safe_navigation_uri ("about:config"));
    assert (!Xanh.AddressResolver.is_safe_navigation_uri ("file:///etc/passwd"));
    assert (!Xanh.AddressResolver.is_safe_navigation_uri ("data:text/html,test"));

    assert (Xanh.AddressResolver.is_safe_external_uri ("mailto:user@example.com"));
    assert (Xanh.AddressResolver.is_safe_external_uri ("tel:+84123456789"));
    assert (Xanh.AddressResolver.is_safe_external_uri ("sms:+84123456789"));
    assert (Xanh.AddressResolver.is_safe_external_uri ("geo:10.0,106.0"));
    assert (Xanh.AddressResolver.is_safe_external_uri ("market://details?id=xanh"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("mailto:"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("intent://example.com"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("javascript:alert(1)"));
    assert (!Xanh.AddressResolver.is_safe_external_uri (
        "mailto:user@example.com?subject=x%0d%0aBcc:other@example.com"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("tel:%00+84123456789"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("mailto:user%20name@example.com"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("mailto:user\\name@example.com"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("mailto:user%5cname@example.com"));
    assert (!Xanh.AddressResolver.is_safe_external_uri ("mailto:user@example.com%ZZ"));
    assert (!Xanh.AddressResolver.is_safe_external_uri (
        "mailto:user@example.com?subject=" + string.nfill (2048, 'a')));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/address/resolve", test_addresses);
    Test.add_func ("/address/safe-web-uri", test_safe_web_uri_policy);
    Test.add_func ("/address/navigation-and-external", test_navigation_and_external_uri_policy);
    return Test.run ();
}
