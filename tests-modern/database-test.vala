/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_history_and_private_mode () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var path = Path.build_filename (dir, "browser.db");
        var database = new Xanh.BrowserDatabase (path);
        database.record_history ("https://example.com", "Example");
        database.record_history ("https://private.example", "Private", true);
        assert (database.list_history ().length () == 1);
    } catch (Error error) {
        Test.fail_printf ("Database error: %s", error.message);
    }
}

void test_bookmark_upsert () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (Path.build_filename (dir, "browser.db"));
        database.add_bookmark ("https://example.com", "First");
        database.add_bookmark ("https://example.com", "Updated");
        var bookmarks = database.list_bookmarks ();
        assert (bookmarks.length () == 1);
        assert (bookmarks.data.title == "Updated");
    } catch (Error error) {
        Test.fail_printf ("Database error: %s", error.message);
    }
}

void test_session_round_trip () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (Path.build_filename (dir, "browser.db"));
        var tabs = new List<Xanh.StoredPage> ();
        tabs.append (new Xanh.StoredPage ("https://one.example", "One"));
        tabs.append (new Xanh.StoredPage ("https://two.example", "Two"));
        database.save_session (tabs, 1);
        int selected;
        var restored = database.load_session (out selected);
        assert (restored.length () == 2);
        assert (selected == 1);
    } catch (Error error) {
        Test.fail_printf ("Database error: %s", error.message);
    }
}

void test_download_round_trip () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (Path.build_filename (dir, "browser.db"));
        database.record_download ("https://example.com/file.pdf", "file:///tmp/file.pdf", "finished");
        var downloads = database.list_downloads ();
        assert (downloads.length () == 1);
        assert (downloads.data.status == "finished");
        assert (downloads.data.destination == "file:///tmp/file.pdf");
    } catch (Error error) {
        Test.fail_printf ("Database error: %s", error.message);
    }
}

void test_import_history_is_idempotent () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (Path.build_filename (dir, "browser.db"));
        database.import_history ("https://example.com/imported", "Imported", 42);
        database.import_history ("https://example.com/imported", "Imported", 42);
        assert (database.list_history ().length () == 1);
    } catch (Error error) {
        Test.fail_printf ("Database error: %s", error.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/database/history-private", test_history_and_private_mode);
    Test.add_func ("/database/bookmark-upsert", test_bookmark_upsert);
    Test.add_func ("/database/session-round-trip", test_session_round_trip);
    Test.add_func ("/database/download-round-trip", test_download_round_trip);
    Test.add_func ("/database/import-history-idempotent", test_import_history_is_idempotent);
    return Test.run ();
}
