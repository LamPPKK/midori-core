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

void test_unsafe_legacy_navigation_data_is_filtered () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (
            Path.build_filename (dir, "browser.db"));
        database.execute ("""
            INSERT INTO history(uri, title, visited_at, private) VALUES
                ('https://safe-history.example/', 'Safe', 10, 0),
                ('https://history.example/%5cunsafe', 'Unsafe', 11, 0),
                ('https://legacy-private.example/', 'Private', 12, 1);
            INSERT INTO bookmarks(uri, title, created_at) VALUES
                ('https://safe-bookmark.example/', 'Safe', 10),
                ('https://user@bookmark.example/', 'Unsafe', 11);
            INSERT INTO places_history_mirror(uri, title, visited_at) VALUES
                ('https://safe-places-history.example/', 'Safe', 10),
                ('https://foo_bar.example/', 'Unsafe', 11);
            INSERT INTO places_bookmarks_mirror(uri, title, created_at) VALUES
                ('https://safe-places-bookmark.example/', 'Safe', 10),
                ('https://places.example/%0dunsafe', 'Unsafe', 11);
            INSERT INTO session_tabs(position, uri, title, selected) VALUES
                (0, 'javascript:alert(1)', 'Unsafe', 1),
                (1, 'https://safe-session.example/', 'Safe', 0),
                (2, 'about:blank', 'Blank', 0),
                (3, 'ABOUT:BLANK', 'Noncanonical', 0);
        """);

        assert (database.list_history (10).length () == 1);
        assert (database.list_bookmarks (10).length () == 1);
        assert (database.list_places_history (10).length () == 1);
        assert (database.list_places_bookmarks (10).length () == 1);
        assert (database.list_history_page (10, 0).length () == 2);
        assert (database.list_bookmarks_page (10, 0).length () == 2);
        assert (!database.has_bookmark ("https://user@bookmark.example/"));

        int selected;
        var restored = database.load_session (out selected);
        assert (restored.length () == 2);
        assert (selected == 0);
        assert (restored.data.uri == "https://safe-session.example/");
        assert (restored.next.data.uri == "about:blank");

        var tabs = new List<Xanh.StoredPage> ();
        tabs.append (new Xanh.StoredPage ("data:text/html,unsafe", "Unsafe"));
        tabs.append (new Xanh.StoredPage ("https://saved.example/", "Saved"));
        tabs.append (new Xanh.StoredPage ("about:blank", "Blank"));
        database.save_session (tabs, 0);
        restored = database.load_session (out selected);
        assert (restored.length () == 2);
        assert (selected == 0);
        assert (restored.data.uri == "https://saved.example/");
        database.save_session (tabs, 2);
        restored = database.load_session (out selected);
        assert (restored.length () == 2);
        assert (selected == 1);

        bool bookmark_rejected = false;
        bool history_rejected = false;
        try {
            database.upsert_places_bookmark (
                new Xanh.StoredPage ("https://user@unsafe.example/", "Unsafe"));
        } catch (Xanh.DatabaseError error) {
            bookmark_rejected = true;
        }
        try {
            database.append_places_history (
                new Xanh.StoredPage ("https://unsafe.example/%5cpath", "Unsafe"));
        } catch (Xanh.DatabaseError error) {
            history_rejected = true;
        }
        assert (bookmark_rejected);
        assert (history_rejected);

        var mirror_bookmarks = new List<Xanh.StoredPage> ();
        mirror_bookmarks.append (new Xanh.StoredPage (
            "https://new-safe-bookmark.example/", "Safe"));
        mirror_bookmarks.append (new Xanh.StoredPage (
            "https://user@new-unsafe-bookmark.example/", "Unsafe"));
        var mirror_history = new List<Xanh.StoredPage> ();
        mirror_history.append (new Xanh.StoredPage (
            "https://new-safe-history.example/", "Safe"));
        mirror_history.append (new Xanh.StoredPage (
            "https://new-unsafe-history.example/%5cpath", "Unsafe"));
        database.replace_places_mirror (mirror_bookmarks, mirror_history);
        assert (database.list_places_bookmarks (10).length () == 1);
        assert (database.list_places_history (10).length () == 1);
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
        bookmarks.append (new Xanh.StoredPage (
            "https://synced.example", "Synced", 100, "AbCdEf123_-x"));
        var history = new List<Xanh.StoredPage> ();
        history.append (new Xanh.StoredPage (
            "https://synced.example/history", "Visit", 101, "", 101123));
        database.replace_places_mirror (bookmarks, history);
        assert (database.get_marker ("places_mirror_v1_ready"));
        assert (database.count_bookmarks () == 1);
        assert (database.list_bookmarks ().data.uri == "https://legacy.example");
        assert (database.list_bookmarks_page (1, 0).data.uri == "https://legacy.example");
        assert (database.count_history () == 1);
        assert (database.list_history ().data.uri == "https://legacy.example/history");
        assert (database.list_places_bookmarks ().data.uri == "https://synced.example");
        assert (database.list_places_history ().data.uri == "https://synced.example/history");
        assert (database.list_places_bookmarks ().data.sync_id == "AbCdEf123_-x");
        assert (database.list_places_history ().data.sync_timestamp_millis == 101123);
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

void create_schema_v1_mirror (string path) {
    Sqlite.Database database;
    assert (Sqlite.Database.open (path, out database) == Sqlite.OK);
    assert (database.exec ("""
        CREATE TABLE schema_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
        CREATE TABLE places_bookmarks_mirror (
            uri TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL);
        CREATE TABLE places_history_mirror (
            id INTEGER PRIMARY KEY AUTOINCREMENT, uri TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '', visited_at INTEGER NOT NULL);
        INSERT INTO places_bookmarks_mirror VALUES('https://old.example/', 'Old', 1);
        INSERT INTO places_history_mirror(uri, title, visited_at)
            VALUES('https://old.example/history', 'Old', 1);
        INSERT INTO schema_meta VALUES('schema_version', '1');
        INSERT INTO schema_meta VALUES('places_mirror_v1_ready', '1');
    """) == Sqlite.OK);
}

void test_schema_v2_sync_identity_upgrade () {
    try {
        var dir = DirUtils.make_tmp ("xanh-browser-test-XXXXXX");
        var path = Path.build_filename (dir, "browser.db");
        create_schema_v1_mirror (path);
        var database = new Xanh.BrowserDatabase (path);
        assert (!database.get_marker ("places_mirror_v1_ready"));
        assert (database.list_places_bookmarks ().length () == 0);
        assert (database.list_places_history ().length () == 0);

        var bookmark = new Xanh.StoredPage (
            "https://new.example/", "New", 2, "AbCdEf123_-x");
        var visit = new Xanh.StoredPage (
            "https://new.example/history", "Visit", 2, "", 2123);
        database.add_bookmark (bookmark.uri, bookmark.title);
        database.import_history (visit.uri, visit.title, visit.visited_at);
        database.upsert_places_bookmark (bookmark);
        database.append_places_history (visit);
        assert (database.list_places_bookmarks ().data.sync_id == "AbCdEf123_-x");
        assert (database.list_places_history ().data.sync_timestamp_millis == 2123);
        var stored_visit = database.list_places_history ().data;
        assert (database.places_bookmark_identity_matches (
            bookmark.uri, "AbCdEf123_-x"));
        assert (!database.places_bookmark_identity_matches (bookmark.uri, "WrongGuid___"));
        assert (database.places_history_identity_matches (
            stored_visit.id, visit.uri, 2123));
        assert (!database.places_history_identity_matches (
            stored_visit.id, visit.uri, 2124));
        database.append_places_history (new Xanh.StoredPage (
            visit.uri, "Pending duplicate", visit.visited_at));
        database.upsert_places_bookmark (new Xanh.StoredPage (
            "https://new.example/", "Offline title", 3));
        assert (database.list_places_bookmarks ().data.sync_id == "AbCdEf123_-x");
        assert (database.finalize_places_bookmark_deletion (
            "AbCdEf123_-x", bookmark.uri));
        assert (database.finalize_places_history_deletion (
            visit.uri, 2123, visit.visited_at, true));
        assert (database.list_places_bookmarks ().length () == 0);
        assert (database.list_places_history ().length () == 0);
        assert (database.list_bookmarks ().length () == 0);
        assert (database.list_history ().length () == 0);

        database.append_places_history (new Xanh.StoredPage (
            "https://remote.example/", "Remote", 4, "", 4123, true));
        assert (database.list_places_history ().data.sync_is_remote);
        assert (database.delete_places_history ("https://remote.example/", 4123));

        database.add_bookmark ("https://pending.example/", "Pending");
        database.import_history ("https://pending.example/history", "Pending", 3);
        database.upsert_places_bookmark (new Xanh.StoredPage (
            "https://pending.example/", "Pending", 3));
        database.append_places_history (new Xanh.StoredPage (
            "https://pending.example/history", "Pending", 3));
        assert (database.delete_pending_bookmark ("https://pending.example/"));
        assert (database.delete_pending_history ("https://pending.example/history", 3));
        assert (database.list_bookmarks ().length () == 0);
        assert (database.list_history ().length () == 0);
        assert (database.list_places_bookmarks ().length () == 0);
        assert (database.list_places_history ().length () == 0);
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
    Test.add_func ("/database/unsafe-legacy-navigation-filter",
        test_unsafe_legacy_navigation_data_is_filtered);
    Test.add_func ("/database/sync-migration-backup-mirror", test_sync_migration_backup_and_mirror);
    Test.add_func ("/database/schema-v2-sync-identity-upgrade",
        test_schema_v2_sync_identity_upgrade);
    return Test.run ();
}
