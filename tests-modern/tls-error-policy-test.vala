/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_prompt_context () {
    string safe = "https://example.com:8443/login?token=secret";
    assert (Xanh.TlsErrorPolicy.is_prompt_context_current (
        safe, safe, true, true, false, false));
    assert (!Xanh.TlsErrorPolicy.is_prompt_context_current (
        safe, "https://example.com:8443/other", true, true, false, false));
    assert (!Xanh.TlsErrorPolicy.is_prompt_context_current (
        "http://example.com/", "http://example.com/", true, true, false, false));
    assert (!Xanh.TlsErrorPolicy.is_prompt_context_current (
        "https://user:secret@example.com/", "https://user:secret@example.com/",
        true, true, false, false));
    assert (!Xanh.TlsErrorPolicy.is_prompt_context_current (
        safe, safe, false, true, false, false));
    assert (!Xanh.TlsErrorPolicy.is_prompt_context_current (
        safe, safe, true, false, false, false));
    assert (!Xanh.TlsErrorPolicy.is_prompt_context_current (
        safe, safe, true, true, true, false));
    assert (!Xanh.TlsErrorPolicy.is_prompt_context_current (
        safe, safe, true, true, false, true));
}

void test_display_origin () {
    assert (Xanh.TlsErrorPolicy.display_origin (
        "https://example.com:8443/path?token=secret") == "https://example.com:8443");
    assert (Xanh.TlsErrorPolicy.display_origin (
        "https://[2001:db8::1]/path") == "https://[2001:db8::1]");
    assert (Xanh.TlsErrorPolicy.display_origin (
        "https://BÜCHER.example/path") == "https://xn--bcher-kva.example");
    assert (Xanh.TlsErrorPolicy.display_origin ("http://example.com/") == null);
    assert (Xanh.TlsErrorPolicy.display_origin (
        "https://user:secret@example.com/") == null);
}

void test_certificate_name_sanitization () {
    assert (Xanh.TlsErrorPolicy.sanitize_certificate_name (null) == "Unknown");
    assert (Xanh.TlsErrorPolicy.sanitize_certificate_name (
        "  Example\r\n\t Certificate  Authority  ") ==
        "Example Certificate Authority");
    assert (Xanh.TlsErrorPolicy.sanitize_certificate_name ("\r\n\t") == "Unknown");
    var directional_name = new StringBuilder ("trusted");
    directional_name.append_unichar (0x202e);
    directional_name.append ("moc.elpmaxe");
    assert (Xanh.TlsErrorPolicy.sanitize_certificate_name (
        directional_name.str) == "trusted moc.elpmaxe");

    var long_name = new StringBuilder ();
    for (int index = 0; index < 600; index++) long_name.append ("ế");
    string sanitized = Xanh.TlsErrorPolicy.sanitize_certificate_name (long_name.str);
    assert (sanitized.length <= Xanh.TlsErrorPolicy.MAX_CERTIFICATE_NAME_BYTES);
    assert (sanitized.char_count () <=
        Xanh.TlsErrorPolicy.MAX_CERTIFICATE_NAME_CHARACTERS);
}

void test_error_description () {
    assert (Xanh.TlsErrorPolicy.describe_errors (
        TlsCertificateFlags.NO_FLAGS) == "certificate validation failed");
    string description = Xanh.TlsErrorPolicy.describe_errors (
        TlsCertificateFlags.UNKNOWN_CA |
        TlsCertificateFlags.BAD_IDENTITY |
        TlsCertificateFlags.REVOKED |
        TlsCertificateFlags.INSECURE);
    assert (description.contains ("unknown certificate authority"));
    assert (description.contains ("site identity mismatch"));
    assert (description.contains ("certificate revoked"));
    assert (description.contains ("insecure certificate algorithm"));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/tls-error-policy/prompt-context", test_prompt_context);
    Test.add_func ("/tls-error-policy/display-origin", test_display_origin);
    Test.add_func ("/tls-error-policy/certificate-name", test_certificate_name_sanitization);
    Test.add_func ("/tls-error-policy/error-description", test_error_description);
    return Test.run ();
}
