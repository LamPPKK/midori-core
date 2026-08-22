/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_prompt_context () {
    string safe = "https://example.com/camera#request";
    assert (Xanh.PermissionPolicy.is_prompt_context_current (
        safe, safe, true, true, false, false));
    assert (!Xanh.PermissionPolicy.is_prompt_context_current (
        safe, "https://example.com/other", true, true, false, false));
    assert (!Xanh.PermissionPolicy.is_prompt_context_current (
        "http://example.com/", "http://example.com/", true, true, false, false));
    assert (!Xanh.PermissionPolicy.is_prompt_context_current (
        "https://user:secret@example.com/", "https://user:secret@example.com/",
        true, true, false, false));
    assert (!Xanh.PermissionPolicy.is_prompt_context_current (
        safe, safe, false, true, false, false));
    assert (!Xanh.PermissionPolicy.is_prompt_context_current (
        safe, safe, true, false, false, false));
    assert (!Xanh.PermissionPolicy.is_prompt_context_current (
        safe, safe, true, true, true, false));
    assert (!Xanh.PermissionPolicy.is_prompt_context_current (
        safe, safe, true, true, false, true));
}

void test_storage_access_context () {
    assert (Xanh.PermissionPolicy.storage_access_matches_document (
        "https://shop.example/path", "SHOP.EXAMPLE", "login.example"));
    assert (Xanh.PermissionPolicy.storage_access_matches_document (
        "https://checkout.shop.example.com/path", "example.com", "login.example"));
    assert (Xanh.PermissionPolicy.storage_access_matches_document (
        "https://bücher.example/path", "xn--bcher-kva.example", "login.example"));
    assert (!Xanh.PermissionPolicy.storage_access_matches_document (
        "http://shop.example/path", "shop.example", "login.example"));
    assert (!Xanh.PermissionPolicy.storage_access_matches_document (
        "https://shop.example.com/path", "notexample.com", "login.example"));
    assert (!Xanh.PermissionPolicy.storage_access_matches_document (
        "https://shop.example/path", "shop.example", "shop.example"));
    assert (!Xanh.PermissionPolicy.storage_access_matches_document (
        "https://shop.example.com/path", "example.com", "id.example.com"));
    assert (!Xanh.PermissionPolicy.storage_access_matches_document (
        "https://shop.example/path", "shop.example", "bad host"));
}

void test_display_origin () {
    assert (Xanh.PermissionPolicy.display_origin (
        "https://example.com:8443/path?token=secret") == "https://example.com:8443");
    assert (Xanh.PermissionPolicy.display_origin (
        "https://[2001:db8::1]/path") == "https://[2001:db8::1]");
    assert (Xanh.PermissionPolicy.display_origin ("http://example.com/") == null);
    assert (Xanh.PermissionPolicy.display_origin (
        "https://user:secret@example.com/") == null);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/permission-policy/prompt-context", test_prompt_context);
    Test.add_func ("/permission-policy/storage-access-context", test_storage_access_context);
    Test.add_func ("/permission-policy/display-origin", test_display_origin);
    return Test.run ();
}
