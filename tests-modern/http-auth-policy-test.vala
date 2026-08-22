/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_prompt_context () {
    string uri = "https://example.com/private?token=secret";
    assert (Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "EXAMPLE.COM", 443, "https", "example.com", 0,
        true, false, false, true, true, false, false));
    assert (Xanh.HttpAuthPolicy.is_prompt_context_current (
        "https://bücher.example:8443/private", "https://bücher.example:8443/private",
        "xn--bcher-kva.example", 8443, "HTTPS", "XN--BCHER-KVA.EXAMPLE", 8443,
        true, false, false, true, true, false, false));

    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "other.example", 443, "https", "example.com", 443,
        true, false, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 444, "https", "example.com", 443,
        true, false, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "http", "example.com", 443,
        true, false, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        "http://example.com/private", "http://example.com/private",
        "example.com", 80, "http", "example.com", 80,
        true, false, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        "https://user:secret@example.com/private",
        "https://user:secret@example.com/private",
        "example.com", 443, "https", "example.com", 443,
        true, false, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, "https://example.com/other", "example.com", 443,
        "https", "example.com", 443,
        true, false, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "https", "example.com", 443,
        false, false, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "https", "example.com", 443,
        true, true, false, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "https", "example.com", 443,
        true, false, true, true, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "https", "example.com", 443,
        true, false, false, false, true, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "https", "example.com", 443,
        true, false, false, true, false, false, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "https", "example.com", 443,
        true, false, false, true, true, true, false));
    assert (!Xanh.HttpAuthPolicy.is_prompt_context_current (
        uri, uri, "example.com", 443, "https", "example.com", 443,
        true, false, false, true, true, false, true));
}

void test_display_origin_and_realm () {
    assert (Xanh.HttpAuthPolicy.display_origin (
        "https://BÜCHER.example:8443/path?token=secret") ==
        "https://xn--bcher-kva.example:8443");
    assert (Xanh.HttpAuthPolicy.display_origin ("http://example.com/") == null);
    assert (Xanh.HttpAuthPolicy.display_origin (
        "https://user:secret@example.com/") == null);
    assert (Xanh.HttpAuthPolicy.sanitize_realm (null) == "Protected area");
    assert (Xanh.HttpAuthPolicy.sanitize_realm (
        "  Private\r\n\tArea  ") == "Private Area");
    var directional = new StringBuilder ("trusted");
    directional.append_unichar (0x202e);
    directional.append ("moc.elpmaxe");
    assert (Xanh.HttpAuthPolicy.sanitize_realm (directional.str) ==
        "trusted moc.elpmaxe");
}

void test_credential_bounds () {
    assert (Xanh.HttpAuthPolicy.credentials_are_bounded ("", ""));
    assert (Xanh.HttpAuthPolicy.credentials_are_bounded ("alice", "correct horse"));

    var username = new StringBuilder ();
    for (int index = 0; index < 600; index++) username.append ("ế");
    assert (!Xanh.HttpAuthPolicy.credentials_are_bounded (username.str, "password"));

    var maximum_password = new StringBuilder ();
    for (int index = 0; index < 4096; index++) maximum_password.append ("a");
    assert (Xanh.HttpAuthPolicy.credentials_are_bounded ("alice", maximum_password.str));
    maximum_password.append ("a");
    assert (!Xanh.HttpAuthPolicy.credentials_are_bounded ("alice", maximum_password.str));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/http-auth-policy/prompt-context", test_prompt_context);
    Test.add_func ("/http-auth-policy/display-and-realm", test_display_origin_and_realm);
    Test.add_func ("/http-auth-policy/credential-bounds", test_credential_bounds);
    return Test.run ();
}
