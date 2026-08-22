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

void test_page_titles_are_sanitized_at_persistence () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (
            Path.build_filename (dir, "browser.db"));
        string unsafe_title = "Before\n\u202eAfter " + string.nfill (5000, 'x');
        database.record_history ("https://history.example", unsafe_title);
        database.add_bookmark ("https://bookmark.example", unsafe_title);
        var tabs = new List<Xanh.StoredPage> ();
        var tab = new Xanh.StoredPage ("https://session.example", "Safe");
        tab.title = unsafe_title;
        tabs.append (tab);
        database.save_session (tabs, 0);
        database.execute (
            "INSERT INTO history(uri, title, visited_at, private) " +
            "VALUES('https://legacy.example', '%s', 1, 0);".printf (unsafe_title));

        string history_title = database.list_history ().data.title;
        string bookmark_title = database.list_bookmarks ().data.title;
        int selected;
        string session_title = database.load_session (out selected).data.title;
        string legacy_title = "";
        foreach (var page in database.list_history (10)) {
            if (page.uri == "https://legacy.example") legacy_title = page.title;
        }
        assert (legacy_title != "");
        string[] titles = {
            history_title, bookmark_title, session_title, legacy_title
        };
        foreach (string title in titles) {
            assert (title.validate ());
            assert (!title.contains ("\n"));
            assert (!title.contains ("\u202e"));
            assert (title.length <= Xanh.PageDataPolicy.MAX_TITLE_BYTES);
        }
    } catch (Error error) {
        Test.fail_printf ("Database error: %s", error.message);
    }
}

void test_sync_migration_backup_and_mirror () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (Path.build_filename (dir, "browser.db"));
        database.add_bookmark ("https://legacy.example", "Legacy bookmark");
        database.import_history ("https://legacy.example/history", "Legacy history", 42);
        string backup_path;
        string checksum = database.backup_for_sync_migration (
            Path.build_filename (dir, "migration"), out backup_path);
        assert (checksum.length == 64);
        assert (File.new_for_path (backup_path).query_exists ());
        var migration_directory = File.new_for_path (Path.build_filename (dir, "migration"));
        var directory_info = migration_directory.query_info (
            FileAttribute.UNIX_MODE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        var backup_info = File.new_for_path (backup_path).query_info (
            FileAttribute.UNIX_MODE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        assert ((directory_info.get_attribute_uint32 (FileAttribute.UNIX_MODE) & 0777) == 0700);
        assert ((backup_info.get_attribute_uint32 (FileAttribute.UNIX_MODE) & 0777) == 0600);
        var backup = new Xanh.BrowserDatabase (backup_path, true);
        assert (backup.count_bookmarks () == 1);
        assert (backup.count_history () == 1);
        uint8[] reopened_contents;
        File.new_for_path (backup_path).load_contents (null, out reopened_contents, null);
        assert (Checksum.compute_for_data (ChecksumType.SHA256, reopened_contents) == checksum);

        database.commit_sync_migration (checksum);
        assert (database.get_marker ("places_migration_v1_complete"));
        assert (database.get_setting ("places_migration_v1_sha256") == checksum);

        var bookmarks = new List<Xanh.StoredPage> ();
        bookmarks.append (new Xanh.StoredPage ("https://synced.example", "Synced", 100));
        var history = new List<Xanh.StoredPage> ();
        history.append (new Xanh.StoredPage ("https://synced.example/history", "Visit", 101));
        database.replace_places_mirror (bookmarks, history);
        assert (database.get_marker ("places_mirror_v1_ready"));
        assert (database.count_bookmarks () == 1);
        assert (database.list_bookmarks ().data.uri == "https://legacy.example");
        assert (database.list_bookmarks_page (1, 0).data.uri == "https://legacy.example");
        assert (database.count_history () == 1);
        assert (database.list_history ().data.uri == "https://legacy.example/history");
        assert (database.list_places_bookmarks ().data.uri == "https://synced.example");
        assert (database.list_places_history ().data.uri == "https://synced.example/history");
        database.upsert_places_bookmark (
            new Xanh.StoredPage ("https://local.example", "Local", 102));
        database.append_places_history (
            new Xanh.StoredPage ("https://local.example/history", "Local visit", 103));
        assert (database.list_places_bookmarks ().data.uri == "https://local.example");
        assert (database.list_places_history ().data.uri == "https://local.example/history");
        database.invalidate_sync_migration ();
        assert (!database.get_marker ("places_migration_v1_complete"));
        assert (database.get_marker ("places_mirror_v1_ready"));
        database.commit_sync_migration (checksum);
        database.set_marker ("places_history_clear_pending");
        database.clear_private_data ();
        assert (database.list_history ().length () == 0);
        assert (database.list_places_history ().length () == 0);
        assert (database.list_places_bookmarks ().length () == 2);
        assert (database.get_marker ("places_history_clear_pending"));
        database.clear_marker ("places_history_clear_pending");
        assert (!database.get_marker ("places_history_clear_pending"));
        database.clear_sync_migration_backup_metadata ();
        assert (database.get_setting ("places_migration_v1_sha256") == null);
        database.commit_sync_migration (checksum);
        database.set_marker ("places_history_clear_pending");
        database.set_marker ("places_snapshot_clear_pending");
        database.reset_sync_local_data ();
        assert (!database.get_marker ("places_migration_v1_complete"));
        assert (!database.get_marker ("places_mirror_v1_ready"));
        assert (!database.get_marker ("places_history_clear_pending"));
        assert (database.get_marker ("places_snapshot_clear_pending"));
        database.clear_marker ("places_snapshot_clear_pending");
        assert (database.get_setting ("places_migration_v1_sha256") == null);
        assert (database.list_places_bookmarks ().length () == 0);
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
    Test.add_func ("/database/page-title-sanitization",
        test_page_titles_are_sanitized_at_persistence);
    Test.add_func ("/database/sync-migration-backup-mirror", test_sync_migration_backup_and_mirror);
    return Test.run ();
}
