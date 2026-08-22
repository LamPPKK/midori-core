/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public errordomain SyncDataError {
        INVALID_DATA,
        MIGRATION
    }

    public class RemoteTabPage : Object {
        public string title { get; construct; }
        public string uri { get; construct; }
        public int64 last_used { get; construct; }
        public bool pinned { get; construct; }

        public RemoteTabPage (string title, string uri, int64 last_used, bool pinned) {
            Object (title: title, uri: uri, last_used: last_used, pinned: pinned);
        }
    }

    public class RemoteTabsDevice : Object {
        public string name { get; construct; }
        public string kind { get; construct; }
        List<RemoteTabPage> tab_items;
        public unowned List<RemoteTabPage> tabs { get { return tab_items; } }

        public RemoteTabsDevice (string name, string kind) {
            Object (name: name, kind: kind);
            tab_items = new List<RemoteTabPage> ();
        }

        public void append (RemoteTabPage page) {
            tab_items.append (page);
        }
    }

    class PreparedMigration : Object {
        public string checksum { get; construct; }
        public BrowserDatabase source { get; construct; }
        public int bookmark_count { get; construct; }
        public int history_count { get; construct; }

        public PreparedMigration (string checksum, BrowserDatabase source,
                int bookmark_count, int history_count) {
            Object (checksum: checksum, source: source, bookmark_count: bookmark_count,
                history_count: history_count);
        }
    }

    public class SyncDataCoordinator : Object {
        const int MAX_LEGACY_BOOKMARKS = 10000;
        const int BOOKMARK_BATCH_SIZE = 500;
        const int HISTORY_BATCH_SIZE = 400;
        const uint MIRROR_HISTORY_LIMIT = 500;

        BrowserDatabase database;
        SyncHost host;
        int migration_generation;
        int active_migrations;

        public SyncDataCoordinator (BrowserDatabase database, SyncHost host) {
            this.database = database;
            this.host = host;
        }

        public async void migrate_once () throws Error {
            if (database.get_marker ("places_migration_v1_complete")) return;
            yield import_current_legacy_data ();
        }

        public async void import_new_legacy_data () throws Error {
            yield import_current_legacy_data ();
        }

        async void import_current_legacy_data () throws Error {
            int generation = migration_generation;
            active_migrations++;
            try {
                yield import_current_legacy_data_generation (generation);
            } finally {
                active_migrations--;
            }
        }

        async void import_current_legacy_data_generation (int generation) throws Error {
            string backup_directory = Path.build_filename (
                Environment.get_user_data_dir (), "xanh-browser", "firefox-sync-migration");
            require_current_migration (generation);
            prune_migration_snapshots (
                database.get_setting ("places_migration_v1_sha256"));
            PreparedMigration snapshot = yield prepare_migration_snapshot (backup_directory);
            require_current_migration (generation);
            string checksum = snapshot.checksum;
            BrowserDatabase source = snapshot.source;
            int bookmark_count = snapshot.bookmark_count;
            int history_count = snapshot.history_count;
            if (bookmark_count > MAX_LEGACY_BOOKMARKS) {
                throw new SyncDataError.MIGRATION (
                    "Legacy bookmark count exceeds the bounded Places migration limit");
            }
            int processed_bookmarks = 0;
            int accepted_bookmarks = 0;
            while (processed_bookmarks < bookmark_count) {
                var page = source.list_bookmarks_page (
                    BOOKMARK_BATCH_SIZE, processed_bookmarks);
                if (page.length () == 0) break;
                int encoded_count;
                string payload = encode_legacy_bookmarks (page, out encoded_count);
                if (encoded_count > 0) {
                    string bookmark_result = yield host.import_legacy_bookmarks_async (payload);
                    require_current_migration (generation);
                    if (result_count (bookmark_result, "accepted_count") != encoded_count) {
                        throw new SyncDataError.MIGRATION (
                            "Places did not acknowledge every valid legacy bookmark");
                    }
                    accepted_bookmarks += encoded_count;
                }
                processed_bookmarks += (int) page.length ();
            }
            if (processed_bookmarks != bookmark_count)
                throw new SyncDataError.MIGRATION (
                    "Migration backup bookmarks could not be read completely");

            int imported_history = 0;
            int accepted_history = 0;
            while (imported_history < history_count) {
                var page = source.list_history_page (HISTORY_BATCH_SIZE, imported_history);
                if (page.length () == 0) break;
                int encoded_count;
                string payload = encode_history (page, out encoded_count);
                if (encoded_count > 0) {
                    string history_result = yield host.record_history_async (payload);
                    require_current_migration (generation);
                    if (result_count (history_result, "accepted_count") != encoded_count) {
                        throw new SyncDataError.MIGRATION (
                            "Places did not acknowledge every valid legacy history visit");
                    }
                    accepted_history += encoded_count;
                }
                imported_history += (int) page.length ();
            }
            if (imported_history != history_count)
                throw new SyncDataError.MIGRATION ("Migration backup history could not be read completely");
            int skipped_bookmarks = bookmark_count - accepted_bookmarks;
            int skipped_history = history_count - accepted_history;
            if (skipped_bookmarks > 0 || skipped_history > 0) {
                warning ("Places migration skipped %d unsafe bookmarks and %d unsafe history visits",
                    skipped_bookmarks, skipped_history);
            }
            prune_migration_snapshots (checksum);
            database.commit_sync_migration (checksum);
            host.mark_local_change ();
        }

        void require_current_migration (int generation) throws SyncDataError {
            if (generation != migration_generation) {
                throw new SyncDataError.MIGRATION (
                    "Places migration was cancelled by Clear Browsing Data");
            }
        }

        public void cancel_migrations_for_history_clear () {
            migration_generation++;
        }

        public async void quiesce_migrations () {
            yield wait_for_migrations ();
        }

        async void wait_for_migrations () {
            while (active_migrations > 0) {
                SourceFunc resume = wait_for_migrations.callback;
                Timeout.add (10, () => {
                    resume ();
                    return Source.REMOVE;
                });
                yield;
            }
        }

        async PreparedMigration prepare_migration_snapshot (string backup_directory)
                throws Error {
            PreparedMigration? prepared = null;
            Error? failure = null;
            SourceFunc resume = prepare_migration_snapshot.callback;
            new Thread<void*> ("xanh-places-migration", () => {
                try {
                    string backup_path;
                    string checksum = database.backup_for_sync_migration (
                        backup_directory, out backup_path);
                    var source = new BrowserDatabase (backup_path, true);
                    int bookmark_count = source.count_bookmarks ();
                    int history_count = source.count_history ();
                    prepared = new PreparedMigration (
                        checksum, source, bookmark_count, history_count);
                } catch (Error error) {
                    failure = error;
                }
                Idle.add ((owned) resume);
                return null;
            });
            yield;
            if (failure != null) throw failure;
            if (prepared == null)
                throw new SyncDataError.MIGRATION ("Migration snapshot preparation failed");
            return prepared;
        }

        public void clear_migration_snapshots () throws Error {
            prune_migration_snapshots (null);
            database.clear_sync_migration_backup_metadata ();
        }

        void prune_migration_snapshots (string? keep_checksum) throws Error {
            string backup_directory = Path.build_filename (
                Environment.get_user_data_dir (), "xanh-browser", "firefox-sync-migration");
            var directory = File.new_for_path (backup_directory);
            FileEnumerator enumerator;
            try {
                enumerator = directory.enumerate_children (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            } catch (IOError.NOT_FOUND error) {
                return;
            }
            string? keep_name = keep_checksum == null ? null :
                "browser-v1-%s.sqlite".printf (keep_checksum);
            FileInfo? info;
            while ((info = enumerator.next_file (null)) != null) {
                string name = info.get_name ();
                if (info.get_file_type () != FileType.REGULAR || name == keep_name ||
                    !is_migration_snapshot_name (name)) continue;
                directory.get_child (name).delete (null);
            }
            enumerator.close (null);
        }

        bool is_migration_snapshot_name (string name) {
            const string PREFIX = "browser-v1-";
            if (!name.has_prefix (PREFIX)) return false;
            if (name.has_suffix (".tmp")) return true;
            if (!name.has_suffix (".sqlite")) return false;
            int digest_length = name.length - PREFIX.length - ".sqlite".length;
            if (digest_length != 64) return false;
            for (int index = PREFIX.length; index < PREFIX.length + digest_length; index++) {
                char value = name[index];
                if (!((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')))
                    return false;
            }
            return true;
        }

        public async void refresh_compatibility_mirror () throws Error {
            int generation = migration_generation;
            var by_uri = new HashTable<string, StoredPage> (str_hash, str_equal);
            for (int root = 0; root < 4; root++) {
                string json = yield host.bookmarks_json_async (root);
                require_current_migration (generation);
                var parser = parse_json (json);
                Json.Array records = require_array (parser);
                records.foreach_element ((array, index, node) => {
                    if (node.get_node_type () != Json.NodeType.OBJECT) return;
                    Json.Object item = node.get_object ();
                    if (item.get_string_member_with_default ("kind", "") != "bookmark" ||
                        !item.get_boolean_member_with_default ("is_openable", false)) return;
                    string? uri = nullable_string (item, "url");
                    if (uri == null || !BrowserDatabase.is_web_uri (uri)) return;
                    string? guid = nullable_string (item, "guid");
                    if (!is_sync_guid (guid)) return;
                    string title = nullable_string (item, "title") ?? uri;
                    int64 millis = item.get_int_member_with_default (
                        "date_added_epoch_millis", 0);
                    if (millis <= 0) return;
                    var page = new StoredPage (uri, title, millis / 1000, guid);
                    StoredPage? previous = by_uri.lookup (uri);
                    if (previous == null || page.visited_at >= previous.visited_at)
                        by_uri.replace (uri, page);
                });
            }
            var bookmarks = new List<StoredPage> ();
            by_uri.foreach ((uri, page) => bookmarks.append (page));

            string history_json = yield host.recent_history_json_async (MIRROR_HISTORY_LIMIT);
            require_current_migration (generation);
            var history_parser = parse_json (history_json);
            Json.Array history_records = require_array (history_parser);
            var history = new List<StoredPage> ();
            history_records.foreach_element ((array, index, node) => {
                if (node.get_node_type () != Json.NodeType.OBJECT) return;
                Json.Object item = node.get_object ();
                string? uri = nullable_string (item, "url");
                if (uri == null || !BrowserDatabase.is_web_uri (uri)) return;
                string title = nullable_string (item, "title") ?? uri;
                int64 millis = item.get_int_member_with_default (
                    "visited_at_epoch_millis", 0);
                if (millis <= 0) return;
                bool is_remote = item.get_boolean_member_with_default (
                    "is_remote", false);
                history.append (new StoredPage (
                    uri, title, millis / 1000, "", millis, is_remote));
            });
            require_current_migration (generation);
            database.replace_places_mirror (bookmarks, history);
        }

        public async void save_bookmark (string uri, string title) throws Error {
            if (!is_sync_web_uri (uri)) return;
            var pages = new List<StoredPage> ();
            var page = new StoredPage (
                uri, sanitized_sync_title (title), new DateTime.now_utc ().to_unix ());
            pages.append (page);
            int encoded_count;
            string result = yield host.import_legacy_bookmarks_async (
                encode_legacy_bookmarks (pages, out encoded_count));
            if (encoded_count != 1 || result_count (result, "accepted_count") != 1) {
                throw new SyncDataError.INVALID_DATA ("Places did not save the bookmark");
            }
            int created = result_count (result, "created_count");
            int existing = result_count (result, "existing_count");
            if (!((created == 1 && existing == 0) ||
                    (created == 0 && existing == 1))) {
                throw new SyncDataError.INVALID_DATA (
                    "Places returned inconsistent bookmark import counts");
            }
            // The importer returns counts, not the durable Places GUID. Always
            // refresh before presenting the row so later deletion can create
            // the exact Sync tombstone instead of guessing from its URL.
            yield refresh_compatibility_mirror ();
            host.mark_local_change ();
        }

        public async void record_history (string uri, string title, bool private_mode) throws Error {
            if (private_mode || !is_sync_web_uri (uri)) return;
            var pages = new List<StoredPage> ();
            var page = new StoredPage (
                uri, sanitized_sync_title (title), new DateTime.now_utc ().to_unix ());
            pages.append (page);
            int encoded_count;
            string result = yield host.record_history_async (
                encode_history (pages, out encoded_count));
            if (encoded_count != 1 || result_count (result, "accepted_count") != 1) {
                throw new SyncDataError.INVALID_DATA ("Places did not save the history visit");
            }
            page.sync_timestamp_millis = checked_millis (page.visited_at);
            database.append_places_history (page);
            host.mark_local_change ();
        }

        public async void delete_bookmark (StoredPage page) throws Error {
            if (!is_sync_guid (page.sync_id))
                throw new SyncDataError.INVALID_DATA (
                    "The bookmark mirror has no durable Places identity");
            if (!(yield host.delete_bookmark_async (page.sync_id, false)))
                throw new SyncDataError.INVALID_DATA (
                    "Places did not acknowledge the bookmark deletion");
            database.finalize_places_bookmark_deletion (page.sync_id, page.uri);
            host.mark_local_change ();
        }

        public async void delete_history (StoredPage page) throws Error {
            if (!is_sync_web_uri (page.uri) || page.sync_timestamp_millis <= 0)
                throw new SyncDataError.INVALID_DATA (
                    "The history mirror has no exact Places visit identity");
            if (!(yield host.delete_history_visit_async (
                    page.uri, page.sync_timestamp_millis)))
                throw new SyncDataError.INVALID_DATA (
                    "Places did not acknowledge the history deletion");
            database.finalize_places_history_deletion (
                page.uri, page.sync_timestamp_millis, page.visited_at,
                !page.sync_is_remote);
            host.mark_local_change ();
        }

        public async void clear_history () throws Error {
            yield wait_for_migrations ();
            if (!(yield host.clear_history_async ())) {
                throw new SyncDataError.INVALID_DATA ("Places did not clear local history");
            }
            host.mark_local_change ();
        }

        public async List<RemoteTabsDevice> remote_tabs () throws Error {
            string json = yield host.remote_tabs_json_async ();
            var parser = parse_json (json);
            Json.Array devices_json = require_array (parser);
            var devices = new List<RemoteTabsDevice> ();
            devices_json.foreach_element ((array, index, node) => {
                if (node.get_node_type () != Json.NodeType.OBJECT) return;
                Json.Object item = node.get_object ();
                var device = new RemoteTabsDevice (
                    item.get_string_member_with_default ("device_name", "Firefox device"),
                    item.get_string_member_with_default ("device_kind", "unknown"));
                Json.Array? tabs = item.get_array_member ("tabs");
                if (tabs != null) {
                    tabs.foreach_element ((tab_array, tab_index, tab_node) => {
                        if (tab_node.get_node_type () != Json.NodeType.OBJECT) return;
                        Json.Object tab = tab_node.get_object ();
                        Json.Array? urls = tab.get_array_member ("url_history");
                        if (urls == null || urls.get_length () == 0) return;
                        string uri = urls.get_string_element (0);
                        if (!BrowserDatabase.is_web_uri (uri)) return;
                        device.append (new RemoteTabPage (
                            tab.get_string_member_with_default ("title", uri), uri,
                            tab.get_int_member_with_default ("last_used_epoch_millis", 0) / 1000,
                            tab.get_boolean_member_with_default ("is_pinned", false)));
                    });
                }
                if (device.tabs.length () > 0) devices.append (device);
            });
            return (owned) devices;
        }

        static string encode_legacy_bookmarks (List<StoredPage> pages, out int encoded_count)
                throws SyncDataError {
            encoded_count = 0;
            var builder = new Json.Builder ();
            builder.begin_array ();
            foreach (var page in pages) {
                if (!is_sync_web_uri (page.uri) || !valid_sync_timestamp (page.visited_at))
                    continue;
                builder.begin_object ();
                builder.set_member_name ("url");
                builder.add_string_value (page.uri);
                builder.set_member_name ("title");
                builder.add_string_value (sanitized_sync_title (page.title));
                builder.set_member_name ("created_at_epoch_millis");
                builder.add_int_value (checked_millis (page.visited_at));
                builder.end_object ();
                encoded_count++;
            }
            builder.end_array ();
            return generate_json (builder);
        }

        static string encode_history (List<StoredPage> pages, out int encoded_count)
                throws SyncDataError {
            encoded_count = 0;
            var builder = new Json.Builder ();
            builder.begin_array ();
            foreach (var page in pages) {
                if (!is_sync_web_uri (page.uri) || !valid_sync_timestamp (page.visited_at))
                    continue;
                builder.begin_object ();
                builder.set_member_name ("url");
                builder.add_string_value (page.uri);
                builder.set_member_name ("title");
                builder.add_string_value (sanitized_sync_title (page.title));
                builder.set_member_name ("visited_at_epoch_millis");
                builder.add_int_value (checked_millis (page.visited_at));
                builder.set_member_name ("transition");
                builder.add_string_value ("link");
                builder.set_member_name ("is_private");
                builder.add_boolean_value (false);
                builder.end_object ();
                encoded_count++;
            }
            builder.end_array ();
            return generate_json (builder);
        }

        static int64 checked_millis (int64 seconds) throws SyncDataError {
            if (seconds <= 0 || seconds > int64.MAX / 1000) {
                throw new SyncDataError.INVALID_DATA ("Legacy timestamp is out of range");
            }
            return seconds * 1000;
        }

        static bool valid_sync_timestamp (int64 seconds) {
            return seconds > 0 && seconds <= int64.MAX / 1000;
        }

        public static bool is_sync_web_uri (string? uri) {
            return PageDataPolicy.is_safe_web_uri (uri);
        }

        public static bool is_sync_guid (string? guid) {
            if (guid == null || guid.length != 12) return false;
            for (int index = 0; index < guid.length; index++) {
                char value = guid[index];
                if (!((value >= 'a' && value <= 'z') ||
                      (value >= 'A' && value <= 'Z') ||
                      (value >= '0' && value <= '9') ||
                      value == '_' || value == '-')) return false;
            }
            return true;
        }

        public static string sanitized_sync_title (string? value) {
            return PageDataPolicy.sanitized_title (value, "Untitled");
        }

        static string generate_json (Json.Builder builder) {
            var generator = new Json.Generator ();
            generator.root = builder.get_root ();
            return generator.to_data (null);
        }

        static Json.Parser parse_json (string value) throws Error {
            var parser = new Json.Parser ();
            parser.load_from_data (value);
            return parser;
        }

        static Json.Array require_array (Json.Parser parser) throws SyncDataError {
            Json.Node? root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) {
                throw new SyncDataError.INVALID_DATA ("Firefox Sync returned invalid list data");
            }
            return root.get_array ();
        }

        static int result_count (string value, string member) throws Error {
            var parser = parse_json (value);
            Json.Node? root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                throw new SyncDataError.INVALID_DATA ("Firefox Sync returned an invalid result");
            }
            int64 count = root.get_object ().get_int_member_with_default (member, -1);
            if (count < 0 || count > int.MAX) {
                throw new SyncDataError.INVALID_DATA ("Firefox Sync returned an invalid count");
            }
            return (int) count;
        }

        static string? nullable_string (Json.Object object, string member) {
            if (!object.has_member (member)) return null;
            Json.Node? node = object.get_member (member);
            return node == null || node.get_node_type () == Json.NodeType.NULL
                ? null : node.get_string ();
        }
    }
}
