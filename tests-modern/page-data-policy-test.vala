/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_title_normalization () {
    assert (Xanh.PageDataPolicy.sanitized_title (
        "  Before\n\tAfter  ") == "Before After");
    assert (Xanh.PageDataPolicy.sanitized_title (
        "safe\u202eevil\u2066text\u2069") == "safeeviltext");
    assert (Xanh.PageDataPolicy.sanitized_title (
        "left\u061cright\u206fend") == "leftrightend");
    assert (Xanh.PageDataPolicy.sanitized_title (
        "emoji 👩\u200d💻 title") == "emoji 👩💻 title");
    assert (Xanh.PageDataPolicy.sanitized_title (
        "\n\t", "https://example.com/page") == "https://example.com/page");
    assert (Xanh.PageDataPolicy.sanitized_title (null, null) == "Untitled");
}

void test_title_byte_limit () {
    string ascii = Xanh.PageDataPolicy.sanitized_title (string.nfill (5000, 'a'));
    assert (ascii.length == Xanh.PageDataPolicy.MAX_TITLE_BYTES);
    string unicode = Xanh.PageDataPolicy.sanitized_title (
        string.nfill (4093, 'a') + "🙂" + "tail");
    assert (unicode.validate ());
    assert (unicode.length == 4093);
    assert (unicode.length <= Xanh.PageDataPolicy.MAX_TITLE_BYTES);
    string fallback = Xanh.PageDataPolicy.sanitized_title (
        "\n", string.nfill (5000, 'b'));
    assert (fallback.length == Xanh.PageDataPolicy.MAX_TITLE_BYTES);
}

void test_web_uri_policy () {
    assert (Xanh.PageDataPolicy.is_safe_web_uri ("https://example.com/path"));
    assert (Xanh.PageDataPolicy.is_safe_web_uri ("https://bücher.example/path"));
    assert (!Xanh.PageDataPolicy.is_safe_web_uri (
        "https://user:secret@example.com/path"));
    assert (!Xanh.PageDataPolicy.is_safe_web_uri ("https://foo_bar.example/"));
    assert (!Xanh.PageDataPolicy.is_safe_web_uri ("https://example.com:70000/"));
    assert (!Xanh.PageDataPolicy.is_safe_web_uri (
        "https://example.com/%0d%0aheader"));
    assert (!Xanh.PageDataPolicy.is_safe_web_uri (
        "https://example.com\\@evil.example/"));
    assert (!Xanh.PageDataPolicy.is_safe_web_uri (
        "https://example.com/%5cevil"));
    assert (!Xanh.PageDataPolicy.is_safe_web_uri (
        "https://example.com/" + string.nfill (
            Xanh.PageDataPolicy.MAX_WEB_URI_BYTES, 'a')));
    assert (Xanh.PageDataPolicy.is_safe_navigation_uri ("about:blank"));
    assert (Xanh.PageDataPolicy.is_safe_navigation_uri ("https://example.com/"));
    assert (!Xanh.PageDataPolicy.is_safe_navigation_uri ("ABOUT:BLANK"));
    assert (!Xanh.PageDataPolicy.is_safe_navigation_uri ("about:blank#fragment"));
    assert (!Xanh.PageDataPolicy.is_safe_navigation_uri ("data:text/html,test"));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/page-data/title-normalization", test_title_normalization);
    Test.add_func ("/page-data/title-byte-limit", test_title_byte_limit);
    Test.add_func ("/page-data/web-uri-policy", test_web_uri_policy);
    return Test.run ();
}
