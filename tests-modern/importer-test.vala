/* SPDX-License-Identifier: LGPL-2.1-or-later */

void create_legacy_database (string profile) throws Error {
    DirUtils.create_with_parents (profile, 0700);
    Sqlite.Database bookmarks;
    Sqlite.Database.open (Path.build_filename (profile, "bookmarks.db"), out bookmarks);
    bookmarks.exec ("CREATE TABLE bookmarks(uri TEXT, title TEXT);" +
        "INSERT INTO bookmarks VALUES('https://example.com', 'Example');");
    Sqlite.Database history;
    Sqlite.Database.open (Path.build_filename (profile, "history.db"), out history);
    history.exec ("CREATE TABLE history(uri TEXT, title TEXT, date INTEGER);" +
        "INSERT INTO history VALUES('https://example.com/page', 'Page', 42);");
    File.new_for_path (Path.build_filename (profile, "config")).replace_contents (
        "[settings]\nhomepage=https://example.com\nenable-javascript=true\n".data,
        null, false, FileCreateFlags.REPLACE_DESTINATION, null);
}

void test_import_is_confirmed_by_caller_and_idempotent () {
    try {
        string root = DirUtils.make_tmp ("xanh-import-test-XXXXXX");
        string profile = Path.build_filename (root, "legacy");
        create_legacy_database (profile);
        var database = new Xanh.BrowserDatabase (Path.build_filename (root, "new.db"));
        var importer = new Xanh.ProfileImporter (database, profile);
        assert (importer.is_available ());
        var first = importer.import_once ();
        assert (first.bookmarks == 1);
        assert (first.history == 1);
        assert (first.settings == 2);
        var second = importer.import_once ();
        assert (second.bookmarks == 0);
        assert (database.list_bookmarks ().length () == 1);
        assert (database.list_history ().length () == 1);
    } catch (Error error) {
        Test.fail_printf ("Importer error: %s", error.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/importer/idempotent", test_import_is_confirmed_by_caller_and_idempotent);
    return Test.run ();
}
