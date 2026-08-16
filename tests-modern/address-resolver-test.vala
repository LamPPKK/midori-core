/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_addresses () {
    assert (Xanh.AddressResolver.resolve ("https://example.com") == "https://example.com");
    assert (Xanh.AddressResolver.resolve ("example.com") == "https://example.com");
    assert (Xanh.AddressResolver.resolve ("localhost:8080") == "https://localhost:8080");
    assert (Xanh.AddressResolver.resolve ("xanh browser").has_prefix ("https://duckduckgo.com/?q="));
    assert (Xanh.AddressResolver.resolve ("50% xanh", "https://example.com/%20?q=%s&literal=%n") ==
        "https://example.com/%20?q=50%25%20xanh&literal=%n");
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/address/resolve", test_addresses);
    return Test.run ();
}
