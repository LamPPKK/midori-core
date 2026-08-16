/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_host_permissions () {
    string[] exact = { "https://*.example.com/*" };
    assert (Xanh.WebExtensionBridge.is_host_allowed ("https://www.example.com/page", exact));
    assert (Xanh.WebExtensionBridge.is_host_allowed ("https://example.com/page", exact));
    assert (!Xanh.WebExtensionBridge.is_host_allowed ("http://www.example.com/page", exact));
    assert (!Xanh.WebExtensionBridge.is_host_allowed ("https://example.net/page", exact));
    string[] all = { "<all_urls>" };
    assert (Xanh.WebExtensionBridge.is_host_allowed ("http://localhost/", all));
    assert (!Xanh.WebExtensionBridge.is_host_allowed ("file:///tmp/secret", all));
}

void test_extension_path_boundary () {
    assert (Xanh.WebExtensionBridge.is_path_within_root (
        "/tmp/xanh-extension", "/tmp/xanh-extension/popup/index.html"));
    assert (!Xanh.WebExtensionBridge.is_path_within_root (
        "/tmp/xanh-extension", "/tmp/secrets.txt"));
    assert (!Xanh.WebExtensionBridge.is_path_within_root (
        "/tmp/xanh-extension", "/tmp/xanh-extension-other/icon.png"));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/web-extension/host-permissions", test_host_permissions);
    Test.add_func ("/web-extension/path-boundary", test_extension_path_boundary);
    return Test.run ();
}
