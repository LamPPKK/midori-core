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
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/address/resolve", test_addresses);
    Test.add_func ("/address/safe-web-uri", test_safe_web_uri_policy);
    return Test.run ();
}
