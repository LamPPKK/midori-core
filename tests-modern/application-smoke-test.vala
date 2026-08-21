/* SPDX-License-Identifier: LGPL-2.1-or-later */

int main (string[] args) {
    try {
        string root = DirUtils.make_tmp ("xanh-application-test-XXXXXX");
        Environment.set_variable ("XDG_DATA_HOME", Path.build_filename (root, "data"), true);
        Environment.set_variable ("XDG_CACHE_HOME", Path.build_filename (root, "cache"), true);
        Environment.set_variable ("XDG_CONFIG_HOME", Path.build_filename (root, "config"), true);
        string browser_data = Path.build_filename (root, "data", "xanh-browser");
        var database = new Xanh.BrowserDatabase (
            Path.build_filename (browser_data, "browser.db"));
        const string CHECKSUM =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        var application = new Xanh.BrowserApplication ();
        database.commit_sync_migration (CHECKSUM);
        application.record_synced_history (new Xanh.TabState () {
            uri = "https://offline.example/history", title = "Offline history"
        });
        if (database.get_marker ("places_migration_v1_complete")) {
            critical ("Offline history did not invalidate the Places migration");
            return 1;
        }
        database.commit_sync_migration (CHECKSUM);
        application.save_synced_bookmark (new Xanh.TabState () {
            uri = "https://offline.example/bookmark", title = "Offline bookmark"
        });
        if (database.get_marker ("places_migration_v1_complete")) {
            critical ("Offline bookmark did not invalidate the Places migration");
            return 1;
        }
        var bookmarks = new List<Xanh.StoredPage> ();
        bookmarks.append (new Xanh.StoredPage ("https://stale.example", "Stale", 1));
        var history = new List<Xanh.StoredPage> ();
        history.append (new Xanh.StoredPage ("https://stale.example/history", "Stale", 1));
        database.replace_places_mirror (bookmarks, history);
        var reset_marker = File.new_for_path (
            Path.build_filename (browser_data, "sync-device-data-reset-pending"));
        var marker_stream = reset_marker.create (FileCreateFlags.PRIVATE, null);
        marker_stream.close (null);
        string migration_path = Path.build_filename (
            browser_data, "firefox-sync-migration");
        var migration_directory = File.new_for_path (migration_path);
        migration_directory.make_directory_with_parents (null);
        var stale_snapshot = File.new_for_path (Path.build_filename (
            migration_path,
            "browser-v1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.sqlite"));
        var snapshot_stream = stale_snapshot.create (FileCreateFlags.PRIVATE, null);
        snapshot_stream.close (null);
        Timeout.add_seconds (3, () => {
            application.quit ();
            return Source.REMOVE;
        });
        int status = application.run (args);
        var reopened = new Xanh.BrowserDatabase (
            Path.build_filename (browser_data, "browser.db"));
        if (reopened.list_places_bookmarks ().length () != 0 ||
                reopened.list_places_history ().length () != 0 ||
                reopened.get_marker ("places_snapshot_clear_pending") ||
                !reset_marker.query_exists () || stale_snapshot.query_exists ()) {
            critical ("Pending device-data reset did not finish its local startup phase");
            return 1;
        }
        return status;
    } catch (Error error) {
        critical ("Application smoke test failed: %s", error.message);
        return 1;
    }
}
