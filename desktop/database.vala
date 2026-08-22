/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public errordomain DatabaseError {
        OPEN,
        QUERY,
        MIGRATION
    }

    public class StoredPage : Object {
        public int64 id { get; set; }
        public string uri { get; set; }
        public string title { get; set; }
        public int64 visited_at { get; set; }

        public StoredPage (string uri, string title, int64 visited_at = 0) {
            string fallback = PageDataPolicy.is_safe_web_uri (uri) ? uri : "Untitled";
            Object (uri: uri, title: PageDataPolicy.sanitized_title (title, fallback),
                visited_at: visited_at);
        }
    }

    public class StoredDownload : Object {
        public int64 id { get; set; }
        public string uri { get; set; }
        public string destination { get; set; }
        public string status { get; set; }
        public int64 created_at { get; set; }

        public StoredDownload (string uri, string destination, string status, int64 created_at = 0) {
            Object (uri: uri, destination: destination, status: status, created_at: created_at);
        }
    }

    public class BrowserDatabase : Object {
        Sqlite.Database handle;
        public string path { get; construct; }
        public bool read_only { get; construct; }

        public BrowserDatabase (string? path = null, bool read_only = false) throws DatabaseError {
            string resolved = path ?? Path.build_filename (
                Environment.get_user_data_dir (), "xanh-browser", "browser.db");
            Object (path: resolved, read_only: read_only);
            open ();
            if (!read_only) migrate ();
        }

        void open () throws DatabaseError {
            if (read_only) {
                if (Sqlite.Database.open_v2 (path, out handle,
                        Sqlite.OPEN_READONLY | Sqlite.OPEN_FULLMUTEX) != Sqlite.OK) {
                    throw new DatabaseError.OPEN ("Cannot open read-only snapshot %s", path);
                }
                execute ("PRAGMA query_only = ON;");
                return;
            }
            var parent = File.new_for_path (path).get_parent ();
            if (parent != null) {
                try {
                    parent.make_directory_with_parents ();
                } catch (IOError.EXISTS error) {
                    // The data directory already exists.
                } catch (Error error) {
                    throw new DatabaseError.OPEN ("Cannot create data directory: %s", error.message);
                }
            }

            if (Sqlite.Database.open_v2 (path, out handle,
                    Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE | Sqlite.OPEN_FULLMUTEX) != Sqlite.OK) {
                throw new DatabaseError.OPEN ("Cannot open %s", path);
            }
            execute ("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
        }

        void migrate () throws DatabaseError {
            execute ("""
                CREATE TABLE IF NOT EXISTS schema_meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uri TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    visited_at INTEGER NOT NULL,
                    private INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS history_uri_date ON history(uri, visited_at DESC);
                CREATE TABLE IF NOT EXISTS bookmarks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uri TEXT UNIQUE NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS places_history_mirror (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uri TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    visited_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS places_history_mirror_date
                    ON places_history_mirror(visited_at DESC);
                CREATE TABLE IF NOT EXISTS places_bookmarks_mirror (
                    uri TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS downloads (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uri TEXT NOT NULL,
                    destination TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS session_tabs (
                    position INTEGER PRIMARY KEY,
                    uri TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    selected INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                INSERT OR REPLACE INTO schema_meta(key, value) VALUES('schema_version', '1');
            """);
        }

        public void execute (string sql) throws DatabaseError {
            if (handle.exec (sql) != Sqlite.OK) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
        }

        public void record_history (string uri, string title, bool private_mode = false) throws DatabaseError {
            if (private_mode || !is_web_uri (uri)) {
                return;
            }
            Sqlite.Statement statement;
            string safe_title = PageDataPolicy.sanitized_title (title, uri);
            prepare ("INSERT INTO history(uri, title, visited_at, private) VALUES(?, ?, ?, 0)", out statement);
            statement.bind_text (1, uri);
            statement.bind_text (2, safe_title);
            statement.bind_int64 (3, new DateTime.now_utc ().to_unix ());
            step_done (statement);
        }

        public void import_history (string uri, string title, int64 visited_at) throws DatabaseError {
            if (!is_web_uri (uri)) {
                return;
            }
            string safe_title = PageDataPolicy.sanitized_title (title, uri);
            Sqlite.Statement statement;
            prepare ("INSERT INTO history(uri, title, visited_at, private) " +
                "SELECT ?, ?, ?, 0 WHERE NOT EXISTS (" +
                "SELECT 1 FROM history WHERE uri = ? AND title = ? AND visited_at = ?)", out statement);
            statement.bind_text (1, uri);
            statement.bind_text (2, safe_title);
            statement.bind_int64 (3, visited_at);
            statement.bind_text (4, uri);
            statement.bind_text (5, safe_title);
            statement.bind_int64 (6, visited_at);
            step_done (statement);
        }

        public void add_bookmark (string uri, string title) throws DatabaseError {
            if (!is_web_uri (uri)) {
                throw new DatabaseError.QUERY ("Only HTTP(S) pages can be bookmarked");
            }
            Sqlite.Statement statement;
            string safe_title = PageDataPolicy.sanitized_title (title, uri);
            prepare ("""
                INSERT INTO bookmarks(uri, title, created_at) VALUES(?, ?, ?)
                ON CONFLICT(uri) DO UPDATE SET title = excluded.title
            """, out statement);
            statement.bind_text (1, uri);
            statement.bind_text (2, safe_title);
            statement.bind_int64 (3, new DateTime.now_utc ().to_unix ());
            step_done (statement);
        }

        public void set_setting (string key, string value) throws DatabaseError {
            Sqlite.Statement statement;
            prepare ("INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)", out statement);
            statement.bind_text (1, key);
            statement.bind_text (2, value);
            step_done (statement);
        }

        public string? get_setting (string key) throws DatabaseError {
            Sqlite.Statement statement;
            prepare ("SELECT value FROM settings WHERE key = ? LIMIT 1", out statement);
            statement.bind_text (1, key);
            return statement.step () == Sqlite.ROW ? statement.column_text (0) : null;
        }

        public bool has_bookmark (string uri) throws DatabaseError {
            if (!is_web_uri (uri)) return false;
            Sqlite.Statement statement;
            prepare ("SELECT 1 FROM bookmarks WHERE uri = ? LIMIT 1", out statement);
            statement.bind_text (1, uri);
            return statement.step () == Sqlite.ROW;
        }

        public List<StoredPage> list_bookmarks (int limit = 100) throws DatabaseError {
            return query_pages (
                "SELECT id, uri, title, created_at FROM bookmarks ORDER BY created_at DESC LIMIT ?", limit);
        }

        public List<StoredPage> list_bookmarks_page (int limit, int offset)
                throws DatabaseError {
            var pages = new List<StoredPage> ();
            Sqlite.Statement statement;
            prepare ("SELECT id, uri, title, created_at FROM bookmarks " +
                "ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?", out statement);
            statement.bind_int (1, limit);
            statement.bind_int (2, offset);
            int result;
            while ((result = statement.step ()) == Sqlite.ROW) {
                var page = new StoredPage (statement.column_text (1), statement.column_text (2),
                    statement.column_int64 (3));
                page.id = statement.column_int64 (0);
                pages.append (page);
            }
            if (result != Sqlite.DONE)
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            return pages;
        }

        public List<StoredPage> list_history (int limit = 100) throws DatabaseError {
            return query_pages (
                "SELECT id, uri, title, visited_at FROM history WHERE private = 0 " +
                "ORDER BY visited_at DESC LIMIT ?", limit);
        }

        public List<StoredPage> list_places_bookmarks (int limit = 100) throws DatabaseError {
            return query_pages (
                "SELECT rowid, uri, title, created_at FROM places_bookmarks_mirror " +
                "ORDER BY created_at DESC LIMIT ?", limit);
        }

        public List<StoredPage> list_places_history (int limit = 100) throws DatabaseError {
            return query_pages (
                "SELECT id, uri, title, visited_at FROM places_history_mirror " +
                "ORDER BY visited_at DESC LIMIT ?", limit);
        }

        public void upsert_places_bookmark (StoredPage page) throws DatabaseError {
            if (!is_web_uri (page.uri)) {
                throw new DatabaseError.QUERY (
                    "Only safe HTTP(S) pages can enter the Places bookmark mirror");
            }
            Sqlite.Statement statement;
            prepare ("INSERT OR REPLACE INTO places_bookmarks_mirror" +
                "(uri, title, created_at) VALUES(?, ?, ?)", out statement);
            statement.bind_text (1, page.uri);
            statement.bind_text (2,
                PageDataPolicy.sanitized_title (page.title, page.uri));
            statement.bind_int64 (3, page.visited_at);
            step_done (statement);
        }

        public void append_places_history (StoredPage page) throws DatabaseError {
            if (!is_web_uri (page.uri)) {
                throw new DatabaseError.QUERY (
                    "Only safe HTTP(S) pages can enter the Places history mirror");
            }
            Sqlite.Statement statement;
            prepare ("INSERT INTO places_history_mirror(uri, title, visited_at) VALUES(?, ?, ?)",
                out statement);
            statement.bind_text (1, page.uri);
            statement.bind_text (2,
                PageDataPolicy.sanitized_title (page.title, page.uri));
            statement.bind_int64 (3, page.visited_at);
            step_done (statement);
            execute ("DELETE FROM places_history_mirror WHERE id NOT IN " +
                "(SELECT id FROM places_history_mirror ORDER BY visited_at DESC, id DESC LIMIT 500)");
        }

        public List<StoredPage> list_history_page (int limit, int offset) throws DatabaseError {
            var pages = new List<StoredPage> ();
            Sqlite.Statement statement;
            prepare ("SELECT id, uri, title, visited_at FROM history " +
                "WHERE private = 0 ORDER BY visited_at DESC, id DESC LIMIT ? OFFSET ?", out statement);
            statement.bind_int (1, limit);
            statement.bind_int (2, offset);
            int result;
            while ((result = statement.step ()) == Sqlite.ROW) {
                var page = new StoredPage (statement.column_text (1), statement.column_text (2),
                    statement.column_int64 (3));
                page.id = statement.column_int64 (0);
                pages.append (page);
            }
            if (result != Sqlite.DONE) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
            return pages;
        }

        public int count_bookmarks () throws DatabaseError {
            return count_rows ("SELECT COUNT(*) FROM bookmarks");
        }

        public int count_history () throws DatabaseError {
            return count_rows ("SELECT COUNT(*) FROM history WHERE private = 0");
        }

        int count_rows (string sql) throws DatabaseError {
            Sqlite.Statement statement;
            prepare (sql, out statement);
            if (statement.step () != Sqlite.ROW) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
            int64 count = statement.column_int64 (0);
            if (count < 0 || count > int.MAX) {
                throw new DatabaseError.QUERY ("Database row count is out of range");
            }
            return (int) count;
        }

        List<StoredPage> query_pages (string sql, int limit) throws DatabaseError {
            var pages = new List<StoredPage> ();
            Sqlite.Statement statement;
            prepare (sql, out statement);
            statement.bind_int (1, limit);
            int result;
            while ((result = statement.step ()) == Sqlite.ROW) {
                string uri = statement.column_text (1);
                if (!is_web_uri (uri)) continue;
                var page = new StoredPage (uri, statement.column_text (2),
                    statement.column_int64 (3));
                page.id = statement.column_int64 (0);
                pages.append (page);
            }
            if (result != Sqlite.DONE) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
            return pages;
        }

        public void save_session (List<StoredPage> tabs, int selected) throws DatabaseError {
            execute ("BEGIN IMMEDIATE; DELETE FROM session_tabs;");
            try {
                int input_position = 0;
                int position = 0;
                bool selected_stored = false;
                foreach (var tab in tabs) {
                    bool is_selected = input_position == selected;
                    input_position++;
                    if (!PageDataPolicy.is_safe_navigation_uri (tab.uri)) continue;
                    Sqlite.Statement statement;
                    prepare ("INSERT INTO session_tabs(position, uri, title, selected) VALUES(?, ?, ?, ?)",
                        out statement);
                    statement.bind_int (1, position);
                    statement.bind_text (2, tab.uri);
                    statement.bind_text (3,
                        PageDataPolicy.sanitized_title (tab.title, tab.uri));
                    statement.bind_int (4, is_selected ? 1 : 0);
                    step_done (statement);
                    if (is_selected) selected_stored = true;
                    position++;
                }
                if (position > 0 && !selected_stored) {
                    execute ("UPDATE session_tabs SET selected = 1 WHERE position = 0;");
                }
                execute ("COMMIT;");
            } catch (DatabaseError error) {
                try {
                    execute ("ROLLBACK;");
                } catch (DatabaseError rollback_error) {
                    warning ("Session rollback failed: %s", rollback_error.message);
                }
                throw error;
            }
        }

        public List<StoredPage> load_session (out int selected) throws DatabaseError {
            selected = 0;
            var tabs = new List<StoredPage> ();
            Sqlite.Statement statement;
            prepare ("SELECT position, uri, title, selected FROM session_tabs ORDER BY position", out statement);
            int result;
            int safe_position = 0;
            bool found_selected = false;
            while ((result = statement.step ()) == Sqlite.ROW) {
                string uri = statement.column_text (1);
                if (!PageDataPolicy.is_safe_navigation_uri (uri)) continue;
                var page = new StoredPage (uri, statement.column_text (2));
                tabs.append (page);
                if (!found_selected && statement.column_int (3) == 1) {
                    selected = safe_position;
                    found_selected = true;
                }
                safe_position++;
            }
            if (result != Sqlite.DONE) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
            return tabs;
        }

        public void record_download (string uri, string destination, string status) throws DatabaseError {
            Sqlite.Statement statement;
            prepare ("INSERT INTO downloads(uri, destination, status, created_at) VALUES(?, ?, ?, ?)", out statement);
            statement.bind_text (1, uri);
            statement.bind_text (2, destination);
            statement.bind_text (3, status);
            statement.bind_int64 (4, new DateTime.now_utc ().to_unix ());
            step_done (statement);
        }

        public List<StoredDownload> list_downloads (int limit = 100) throws DatabaseError {
            var downloads = new List<StoredDownload> ();
            Sqlite.Statement statement;
            prepare ("SELECT id, uri, destination, status, created_at " +
                "FROM downloads ORDER BY created_at DESC, id DESC LIMIT ?", out statement);
            statement.bind_int (1, limit);
            int result;
            while ((result = statement.step ()) == Sqlite.ROW) {
                var download = new StoredDownload (
                    statement.column_text (1), statement.column_text (2),
                    statement.column_text (3), statement.column_int64 (4));
                download.id = statement.column_int64 (0);
                downloads.append (download);
            }
            if (result != Sqlite.DONE) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
            return downloads;
        }

        public void clear_private_data () throws DatabaseError {
            execute ("DELETE FROM history; DELETE FROM places_history_mirror; " +
                "DELETE FROM session_tabs; VACUUM;");
        }

        public bool get_marker (string key) throws DatabaseError {
            Sqlite.Statement statement;
            prepare ("SELECT value FROM schema_meta WHERE key = ? LIMIT 1", out statement);
            statement.bind_text (1, key);
            return statement.step () == Sqlite.ROW && statement.column_text (0) == "1";
        }

        public void set_marker (string key) throws DatabaseError {
            Sqlite.Statement statement;
            prepare ("INSERT OR REPLACE INTO schema_meta(key, value) VALUES(?, '1')", out statement);
            statement.bind_text (1, key);
            step_done (statement);
        }

        public void clear_marker (string key) throws DatabaseError {
            Sqlite.Statement statement;
            prepare ("DELETE FROM schema_meta WHERE key = ?", out statement);
            statement.bind_text (1, key);
            step_done (statement);
        }

        public string backup_for_sync_migration (string backup_directory,
                                                 out string backup_path) throws DatabaseError {
            var parent = File.new_for_path (backup_directory);
            try {
                parent.make_directory_with_parents ();
            } catch (IOError.EXISTS error) {
                // The private migration directory already exists.
            } catch (Error error) {
                throw new DatabaseError.MIGRATION ("Cannot create migration backup directory: %s",
                    error.message);
            }
            try {
                if (parent.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null) !=
                        FileType.DIRECTORY) {
                    throw new DatabaseError.MIGRATION (
                        "Migration backup path is not a private directory");
                }
                parent.set_attribute_uint32 (FileAttribute.UNIX_MODE, 0700,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            } catch (DatabaseError error) {
                throw error;
            } catch (Error error) {
                throw new DatabaseError.MIGRATION (
                    "Cannot secure migration backup directory: %s", error.message);
            }
            string temporary_path = Path.build_filename (backup_directory,
                "browser-v1-%s.tmp".printf (Uuid.string_random ()));
            var temporary = File.new_for_path (temporary_path);
            try {
                var temporary_stream = temporary.create (FileCreateFlags.PRIVATE, null);
                temporary_stream.close (null);
                write_sqlite_backup (temporary_path);
                temporary.set_attribute_uint32 (FileAttribute.UNIX_MODE, 0600,
                    FileQueryInfoFlags.NONE, null);
                FileInfo temporary_info = temporary.query_info (
                    FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                if (temporary_info.get_size () == 0) {
                    throw new DatabaseError.MIGRATION ("Migration backup is empty");
                }
                string checksum = checksum_file (temporary);
                backup_path = Path.build_filename (backup_directory,
                    "browser-v1-%s.sqlite".printf (checksum));
                var backup_file = File.new_for_path (backup_path);
                if (backup_file.query_exists ()) {
                    if (checksum_file (backup_file) != checksum) {
                        throw new DatabaseError.MIGRATION (
                            "Existing content-addressed migration backup is invalid");
                    }
                    temporary.delete ();
                } else {
                    try {
                        temporary.move (backup_file, FileCopyFlags.NONE, null, null);
                    } catch (IOError.EXISTS error) {
                        if (checksum_file (backup_file) != checksum) {
                            throw new DatabaseError.MIGRATION (
                                "Concurrent migration backup is invalid");
                        }
                        temporary.delete ();
                    }
                }
                backup_file.set_attribute_uint32 (FileAttribute.UNIX_MODE, 0600,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                return checksum;
            } catch (DatabaseError error) {
                try { if (temporary.query_exists ()) temporary.delete (); }
                catch (Error cleanup_error) {
                    warning ("Cannot remove failed migration snapshot: %s", cleanup_error.message);
                }
                throw error;
            } catch (Error error) {
                try { if (temporary.query_exists ()) temporary.delete (); }
                catch (Error cleanup_error) {
                    warning ("Cannot remove failed migration snapshot: %s", cleanup_error.message);
                }
                throw new DatabaseError.MIGRATION ("Cannot create verified migration backup: %s",
                    error.message);
            }
        }

        string checksum_file (File file) throws Error {
            var checksum = new Checksum (ChecksumType.SHA256);
            var stream = file.read (null);
            uint8[] buffer = new uint8[64 * 1024];
            ssize_t bytes_read;
            while ((bytes_read = stream.read (buffer, null)) > 0)
                checksum.update (buffer, (size_t) bytes_read);
            stream.close (null);
            return checksum.get_string ();
        }

        void write_sqlite_backup (string destination_path) throws DatabaseError {
            Sqlite.Database destination;
            if (Sqlite.Database.open_v2 (destination_path, out destination,
                    Sqlite.OPEN_READWRITE | Sqlite.OPEN_FULLMUTEX) != Sqlite.OK) {
                throw new DatabaseError.MIGRATION ("Cannot open migration backup database");
            }
            var backup = new Sqlite.Backup (destination, "main", handle, "main");
            int result = backup != null ? backup.step (-1) : Sqlite.ERROR;
            backup = null;
            if (result != Sqlite.DONE) {
                throw new DatabaseError.MIGRATION ("Cannot copy browser database for migration");
            }
            if (destination.exec ("PRAGMA journal_mode = DELETE;") != Sqlite.OK) {
                throw new DatabaseError.MIGRATION (
                    "Cannot finalize migration snapshot journal mode");
            }
        }

        public void commit_sync_migration (string checksum) throws DatabaseError {
            if (checksum.length != 64) {
                throw new DatabaseError.MIGRATION ("Migration checksum is invalid");
            }
            execute ("BEGIN IMMEDIATE;");
            try {
                set_setting ("places_migration_v1_sha256", checksum);
                set_marker ("places_migration_v1_complete");
                execute ("COMMIT;");
            } catch (DatabaseError error) {
                try { execute ("ROLLBACK;"); }
                catch (DatabaseError rollback_error) {
                    warning ("Migration marker rollback failed: %s", rollback_error.message);
                }
                throw error;
            }
        }

        public void replace_places_mirror (List<StoredPage> bookmarks,
                                           List<StoredPage> history) throws DatabaseError {
            execute ("BEGIN IMMEDIATE;");
            try {
                execute ("DELETE FROM places_bookmarks_mirror; DELETE FROM places_history_mirror;");
                foreach (var page in bookmarks) {
                    if (!is_web_uri (page.uri)) continue;
                    Sqlite.Statement statement;
                    prepare ("INSERT INTO places_bookmarks_mirror(uri, title, created_at) VALUES(?, ?, ?)",
                        out statement);
                    statement.bind_text (1, page.uri);
                    statement.bind_text (2,
                        PageDataPolicy.sanitized_title (page.title, page.uri));
                    statement.bind_int64 (3, page.visited_at);
                    step_done (statement);
                }
                foreach (var page in history) {
                    if (!is_web_uri (page.uri)) continue;
                    Sqlite.Statement statement;
                    prepare ("INSERT INTO places_history_mirror(uri, title, visited_at) VALUES(?, ?, ?)",
                        out statement);
                    statement.bind_text (1, page.uri);
                    statement.bind_text (2,
                        PageDataPolicy.sanitized_title (page.title, page.uri));
                    statement.bind_int64 (3, page.visited_at);
                    step_done (statement);
                }
                execute ("INSERT OR REPLACE INTO schema_meta(key, value) " +
                    "VALUES('places_mirror_v1_ready', '1');");
                execute ("COMMIT;");
            } catch (DatabaseError error) {
                try { execute ("ROLLBACK;"); }
                catch (DatabaseError rollback_error) {
                    warning ("Places mirror rollback failed: %s", rollback_error.message);
                }
                throw error;
            }
        }

        public void reset_sync_local_data () throws DatabaseError {
            execute ("BEGIN IMMEDIATE;");
            try {
                execute ("DELETE FROM places_bookmarks_mirror; " +
                    "DELETE FROM places_history_mirror; " +
                    "DELETE FROM schema_meta WHERE key IN " +
                    "('places_migration_v1_complete', 'places_mirror_v1_ready', " +
                    "'places_history_clear_pending'); " +
                    "DELETE FROM settings WHERE key = 'places_migration_v1_sha256';");
                execute ("COMMIT;");
            } catch (DatabaseError error) {
                try { execute ("ROLLBACK;"); }
                catch (DatabaseError rollback_error) {
                    warning ("Sync-local reset rollback failed: %s", rollback_error.message);
                }
                throw error;
            }
        }

        public void invalidate_sync_migration () throws DatabaseError {
            execute ("BEGIN IMMEDIATE;");
            try {
                execute ("DELETE FROM schema_meta WHERE key = 'places_migration_v1_complete'; " +
                    "DELETE FROM settings WHERE key = 'places_migration_v1_sha256';");
                execute ("COMMIT;");
            } catch (DatabaseError error) {
                try { execute ("ROLLBACK;"); }
                catch (DatabaseError rollback_error) {
                    warning ("Sync migration invalidation rollback failed: %s",
                        rollback_error.message);
                }
                throw error;
            }
        }

        public void clear_sync_migration_backup_metadata () throws DatabaseError {
            execute ("DELETE FROM settings WHERE key = 'places_migration_v1_sha256';");
        }

        void prepare (string sql, out Sqlite.Statement statement) throws DatabaseError {
            if (handle.prepare_v2 (sql, -1, out statement) != Sqlite.OK) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
        }

        void step_done (Sqlite.Statement statement) throws DatabaseError {
            if (statement.step () != Sqlite.DONE) {
                throw new DatabaseError.QUERY ("%s", handle.errmsg ());
            }
        }

        public static bool is_web_uri (string? uri) {
            return PageDataPolicy.is_safe_web_uri (uri);
        }
    }
}
