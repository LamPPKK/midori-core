/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_suggested_filename () {
    assert (Xanh.DownloadPolicy.sanitize_suggested_filename (null) == "download");
    assert (Xanh.DownloadPolicy.sanitize_suggested_filename ("") == "download");
    assert (Xanh.DownloadPolicy.sanitize_suggested_filename (
        "../../etc/passwd") == "_.._etc_passwd");
    assert (Xanh.DownloadPolicy.sanitize_suggested_filename (
        "  report\r\n final.pdf  ") == "report final.pdf");
    assert (Xanh.DownloadPolicy.sanitize_suggested_filename (
        " .hidden. ") == "hidden");
    var directional = new StringBuilder ("invoice");
    directional.append_unichar (0x202e);
    directional.append ("fdp.exe");
    assert (Xanh.DownloadPolicy.sanitize_suggested_filename (
        directional.str) == "invoice fdp.exe");

    var long_name = new StringBuilder ();
    for (int index = 0; index < 500; index++) long_name.append ("ế");
    string sanitized = Xanh.DownloadPolicy.sanitize_suggested_filename (long_name.str);
    assert (sanitized.length <= Xanh.DownloadPolicy.MAX_SUGGESTED_NAME_BYTES);
    assert (sanitized.char_count () <=
        Xanh.DownloadPolicy.MAX_SUGGESTED_NAME_CHARACTERS);
}

void test_local_destination () {
    var local = File.new_for_path (Path.build_filename (
        Environment.get_tmp_dir (), "xanh-download.bin"));
    string? local_path = Xanh.DownloadPolicy.local_destination_path (local);
    assert (local_path != null && Path.is_absolute (local_path));
    assert (Xanh.DownloadPolicy.local_destination_path (
        File.new_for_uri ("https://example.com/remote.bin")) == null);

    var long_path = new StringBuilder ("/");
    for (int index = 0; index < 5000; index++) long_path.append ("a");
    assert (Xanh.DownloadPolicy.local_destination_path (
        File.new_for_path (long_path.str)) == null);
}

void test_terminal_status () {
    assert (Xanh.DownloadPolicy.should_record_finished (false));
    assert (!Xanh.DownloadPolicy.should_record_finished (true));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/download-policy/suggested-filename", test_suggested_filename);
    Test.add_func ("/download-policy/local-destination", test_local_destination);
    Test.add_func ("/download-policy/terminal-status", test_terminal_status);
    return Test.run ();
}
