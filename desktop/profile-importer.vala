/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class ImportResult : Object {
        public int bookmarks { get; set; }
        public int history { get; set; }
        public int settings { get; set; }
    }

    public class ProfileImporter : Object {
        const string IMPORT_MARKER = "legacy_midori_profile_imported";
        public BrowserDatabase destination { get; construct; }
        public string legacy_path { get; construct; }

        public ProfileImporter (BrowserDatabase destination, string? legacy_path = null) {
            Object (
                destination: destination,
                legacy_path: legacy_path ?? Path.build_filename (Environment.get_user_config_dir (), "midori")
            );
        }

        public bool is_available () {
            return File.new_for_path (Path.build_filename (legacy_path, "bookmarks.db")).query_exists () ||
                File.new_for_path (Path.build_filename (legacy_path, "history.db")).query_exists () ||
                File.new_for_path (Path.build_filename (legacy_path, "config")).query_exists ();
        }

        public bool has_imported () throws DatabaseError {
            return destination.get_marker (IMPORT_MARKER);
        }

        public ImportResult import_once () throws DatabaseError {
            if (has_imported ()) {
                return new ImportResult ();
            }

            var result = new ImportResult ();
            import_bookmarks (result);
            import_history (result);
            import_settings (result);
            destination.set_marker (IMPORT_MARKER);
            return result;
        }

        void import_bookmarks (ImportResult result) throws DatabaseError {
            string path = Path.build_filename (legacy_path, "bookmarks.db");
            if (!File.new_for_path (path).query_exists ()) {
                return;
            }
            Sqlite.Database source;
            if (Sqlite.Database.open_v2 (path, out source, Sqlite.OPEN_READONLY) != Sqlite.OK) {
                throw new DatabaseError.MIGRATION ("Cannot open legacy bookmark database");
            }
            Sqlite.Statement statement;
            if (source.prepare_v2 (
                    "SELECT uri, COALESCE(title, uri) FROM bookmarks WHERE uri IS NOT NULL AND uri != ''",
                    -1, out statement) != Sqlite.OK) {
                throw new DatabaseError.MIGRATION ("Cannot read legacy bookmarks: %s", source.errmsg ());
            }
            int state;
            while ((state = statement.step ()) == Sqlite.ROW) {
                string uri = statement.column_text (0);
                if (BrowserDatabase.is_web_uri (uri)) {
                    destination.add_bookmark (uri, statement.column_text (1));
                    result.bookmarks++;
                }
            }
            if (state != Sqlite.DONE) {
                throw new DatabaseError.MIGRATION ("Cannot finish legacy bookmark import");
            }
        }

        void import_history (ImportResult result) throws DatabaseError {
            string path = Path.build_filename (legacy_path, "history.db");
            if (!File.new_for_path (path).query_exists ()) {
                return;
            }
            Sqlite.Database source;
            if (Sqlite.Database.open_v2 (path, out source, Sqlite.OPEN_READONLY) != Sqlite.OK) {
                throw new DatabaseError.MIGRATION ("Cannot open legacy history database");
            }
            Sqlite.Statement statement;
            if (source.prepare_v2 (
                    "SELECT uri, COALESCE(title, uri), date FROM history WHERE uri IS NOT NULL AND uri != ''",
                    -1, out statement) != Sqlite.OK) {
                throw new DatabaseError.MIGRATION ("Cannot read legacy history: %s", source.errmsg ());
            }
            int state;
            while ((state = statement.step ()) == Sqlite.ROW) {
                string uri = statement.column_text (0);
                if (BrowserDatabase.is_web_uri (uri)) {
                    destination.import_history (uri, statement.column_text (1), statement.column_int64 (2));
                    result.history++;
                }
            }
            if (state != Sqlite.DONE) {
                throw new DatabaseError.MIGRATION ("Cannot finish legacy history import");
            }
        }

        void import_settings (ImportResult result) throws DatabaseError {
            string path = Path.build_filename (legacy_path, "config");
            if (!File.new_for_path (path).query_exists ()) {
                return;
            }
            var keyfile = new KeyFile ();
            try {
                keyfile.load_from_file (path, KeyFileFlags.NONE);
                string[] allowed = {
                    "homepage", "location-entry-search", "enable-javascript",
                    "enable-spell-checking", "auto-load-images", "first-party-cookies-only"
                };
                foreach (string key in allowed) {
                    if (keyfile.has_key ("settings", key)) {
                        destination.set_setting (key, keyfile.get_value ("settings", key));
                        result.settings++;
                    }
                }
            } catch (KeyFileError error) {
                throw new DatabaseError.MIGRATION ("Cannot read legacy settings: %s", error.message);
            } catch (FileError error) {
                throw new DatabaseError.MIGRATION ("Cannot open legacy settings: %s", error.message);
            }
        }
    }
}
