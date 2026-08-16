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
            Object (uri: uri, title: title, visited_at: visited_at);
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

        public BrowserDatabase (string? path = null) throws DatabaseError {
            string resolved = path ?? Path.build_filename (
                Environment.get_user_data_dir (), "xanh-browser", "browser.db");
            Object (path: resolved);
            open ();
            migrate ();
        }

        void open () throws DatabaseError {
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
            prepare ("INSERT INTO history(uri, title, visited_at, private) VALUES(?, ?, ?, 0)", out statement);
            statement.bind_text (1, uri);
            statement.bind_text (2, title);
            statement.bind_int64 (3, new DateTime.now_utc ().to_unix ());
            step_done (statement);
        }

        public void import_history (string uri, string title, int64 visited_at) throws DatabaseError {
            if (!is_web_uri (uri)) {
                return;
            }
            Sqlite.Statement statement;
            prepare ("INSERT INTO history(uri, title, visited_at, private) " +
                "SELECT ?, ?, ?, 0 WHERE NOT EXISTS (" +
                "SELECT 1 FROM history WHERE uri = ? AND title = ? AND visited_at = ?)", out statement);
            statement.bind_text (1, uri);
            statement.bind_text (2, title);
            statement.bind_int64 (3, visited_at);
            statement.bind_text (4, uri);
            statement.bind_text (5, title);
            statement.bind_int64 (6, visited_at);
            step_done (statement);
        }

        public void add_bookmark (string uri, string title) throws DatabaseError {
            if (!is_web_uri (uri)) {
                throw new DatabaseError.QUERY ("Only HTTP(S) pages can be bookmarked");
            }
            Sqlite.Statement statement;
            prepare ("""
                INSERT INTO bookmarks(uri, title, created_at) VALUES(?, ?, ?)
                ON CONFLICT(uri) DO UPDATE SET title = excluded.title
            """, out statement);
            statement.bind_text (1, uri);
            statement.bind_text (2, title);
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
            Sqlite.Statement statement;
            prepare ("SELECT 1 FROM bookmarks WHERE uri = ? LIMIT 1", out statement);
            statement.bind_text (1, uri);
            return statement.step () == Sqlite.ROW;
        }

        public List<StoredPage> list_bookmarks (int limit = 100) throws DatabaseError {
            return query_pages (
                "SELECT id, uri, title, created_at FROM bookmarks ORDER BY created_at DESC LIMIT ?", limit);
        }

        public List<StoredPage> list_history (int limit = 100) throws DatabaseError {
            return query_pages (
                "SELECT id, uri, title, visited_at FROM history ORDER BY visited_at DESC LIMIT ?", limit);
        }

        List<StoredPage> query_pages (string sql, int limit) throws DatabaseError {
            var pages = new List<StoredPage> ();
            Sqlite.Statement statement;
            prepare (sql, out statement);
            statement.bind_int (1, limit);
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

        public void save_session (List<StoredPage> tabs, int selected) throws DatabaseError {
            execute ("BEGIN IMMEDIATE; DELETE FROM session_tabs;");
            try {
                int position = 0;
                foreach (var tab in tabs) {
                    Sqlite.Statement statement;
                    prepare ("INSERT INTO session_tabs(position, uri, title, selected) VALUES(?, ?, ?, ?)",
                        out statement);
                    statement.bind_int (1, position);
                    statement.bind_text (2, tab.uri);
                    statement.bind_text (3, tab.title);
                    statement.bind_int (4, position == selected ? 1 : 0);
                    step_done (statement);
                    position++;
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
            while ((result = statement.step ()) == Sqlite.ROW) {
                var page = new StoredPage (statement.column_text (1), statement.column_text (2));
                tabs.append (page);
                if (statement.column_int (3) == 1) {
                    selected = statement.column_int (0);
                }
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
            execute ("DELETE FROM history; DELETE FROM session_tabs; VACUUM;");
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
            if (uri == null) {
                return false;
            }
            try {
                var parsed = Uri.parse (uri, UriFlags.NONE);
                return parsed.get_host () != null &&
                    (parsed.get_scheme () == "http" || parsed.get_scheme () == "https");
            } catch (UriError error) {
                return false;
            }
        }
    }
}
