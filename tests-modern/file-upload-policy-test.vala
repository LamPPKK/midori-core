/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_context () {
    assert (Xanh.FileUploadPolicy.can_begin (
        "https://example.com/form", "https://example.com/form",
        true, true, false, false));
    assert (!Xanh.FileUploadPolicy.can_begin (
        "http://example.com/form", "http://example.com/form",
        true, true, false, false));
    assert (!Xanh.FileUploadPolicy.can_begin (
        "https://example.com/form", "https://example.com/other",
        true, true, false, false));
    assert (!Xanh.FileUploadPolicy.can_begin (
        "https://example.com/form", "https://example.com/form",
        false, true, false, false));
    assert (!Xanh.FileUploadPolicy.can_begin (
        "https://example.com/form", "https://example.com/form",
        true, false, false, false));
    assert (!Xanh.FileUploadPolicy.can_begin (
        "https://example.com/form", "https://example.com/form",
        true, true, true, false));
    assert (!Xanh.FileUploadPolicy.can_begin (
        "https://example.com/form", "https://example.com/form",
        true, true, false, true));

    // A native modal chooser may own focus while it is open; completion still
    // requires the exact selected tab, document and process lifecycle.
    assert (Xanh.FileUploadPolicy.can_complete (
        "https://example.com/form", "https://example.com/form",
        true, false, false));
    assert (!Xanh.FileUploadPolicy.can_complete (
        "https://example.com/form", "https://example.com/other",
        true, false, false));
    assert (!Xanh.FileUploadPolicy.can_complete (
        "https://example.com/form", "https://example.com/form",
        false, false, false));
    assert (!Xanh.FileUploadPolicy.can_complete (
        "https://example.com/form", "https://example.com/form",
        true, true, false));
    assert (!Xanh.FileUploadPolicy.can_complete (
        "https://example.com/form", "https://example.com/form",
        true, false, true));
}

void test_origin () {
    assert (Xanh.FileUploadPolicy.display_origin (
        "https://Example.COM/form") == "https://example.com");
    assert (Xanh.FileUploadPolicy.display_origin (
        "https://example.com:8443/form") == "https://example.com:8443");
    assert (Xanh.FileUploadPolicy.display_origin (
        "https://[2001:db8::1]/form") == "https://[2001:db8::1]");
    assert (Xanh.FileUploadPolicy.display_origin (
        "https://bücher.example/form") == "https://xn--bcher-kva.example");
    assert (Xanh.FileUploadPolicy.display_origin ("http://example.com/") == null);
    assert (Xanh.FileUploadPolicy.display_origin (
        "https://user:secret@example.com/") == null);
}

void test_paths () {
    string[] one = { "/tmp/photo.png" };
    assert (Xanh.FileUploadPolicy.selected_paths_are_bounded (one, false));
    assert (Xanh.FileUploadPolicy.selected_paths_are_bounded (one, true));
    string[] two = { "/tmp/a.txt", "/tmp/b.txt" };
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (two, false));
    assert (Xanh.FileUploadPolicy.selected_paths_are_bounded (two, true));
    string[] empty = {};
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (empty, true));
    string[] relative = { "relative.txt" };
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (relative, false));
    string[] duplicate = { "/tmp/a.txt", "/tmp/a.txt" };
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (duplicate, true));
    string[] encoded_separator = { "/tmp/report%2fsecret.txt" };
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (
        encoded_separator, false));
    string[] encoded_nul = { "/tmp/report%00.txt" };
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (encoded_nul, false));
    string[] literal_percent = { "/tmp/100%-complete.txt" };
    assert (Xanh.FileUploadPolicy.selected_paths_are_bounded (
        literal_percent, false));
    string[] overlong = { "/" + string.nfill (
        Xanh.FileUploadPolicy.MAX_PATH_BYTES, 'x') };
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (overlong, false));
    string[] exact_path_limit = { "/" + string.nfill (
        Xanh.FileUploadPolicy.MAX_PATH_BYTES - 1, 'x') };
    assert (Xanh.FileUploadPolicy.selected_paths_are_bounded (
        exact_path_limit, false));

    string[] at_count_limit = {};
    string[] too_many = {};
    for (uint index = 0; index <= Xanh.FileUploadPolicy.MAX_SELECTED_FILES; index++) {
        too_many += "/tmp/file-%u".printf (index);
        if (index < Xanh.FileUploadPolicy.MAX_SELECTED_FILES)
            at_count_limit += "/tmp/file-%u".printf (index);
    }
    assert (Xanh.FileUploadPolicy.selected_paths_are_bounded (
        at_count_limit, true));
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (too_many, true));

    string[] too_large = {};
    for (uint index = 0; index < Xanh.FileUploadPolicy.MAX_SELECTED_FILES; index++) {
        too_large += "/tmp/%02u-%s".printf (
            index, string.nfill (2100, 'x'));
    }
    assert (!Xanh.FileUploadPolicy.selected_paths_are_bounded (too_large, true));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/file-upload/context", test_context);
    Test.add_func ("/file-upload/origin", test_origin);
    Test.add_func ("/file-upload/paths", test_paths);
    return Test.run ();
}
