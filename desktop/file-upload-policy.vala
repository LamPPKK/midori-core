/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class FileUploadPolicy : Object {
        public const uint MAX_SELECTED_FILES = 32;
        public const int MAX_PATH_BYTES = 4096;
        public const int MAX_TOTAL_PATH_BYTES = 64 * 1024;
        public const uint TIMEOUT_SECONDS = 5 * 60;

        public static bool can_begin (
                string? requested_document_uri,
                string? current_document_uri,
                bool window_active,
                bool tab_active,
                bool process_stopped,
                bool clearing_data) {
            return window_active && can_complete (
                requested_document_uri, current_document_uri, tab_active,
                process_stopped, clearing_data);
        }

        public static bool can_complete (
                string? requested_document_uri,
                string? current_document_uri,
                bool tab_active,
                bool process_stopped,
                bool clearing_data) {
            return tab_active && !process_stopped && !clearing_data &&
                requested_document_uri != null &&
                requested_document_uri == current_document_uri &&
                AddressResolver.is_safe_secure_web_uri (requested_document_uri);
        }

        public static string? display_origin (string? document_uri) {
            if (!AddressResolver.is_safe_secure_web_uri (document_uri)) return null;
            try {
                var parsed = Uri.parse (document_uri, UriFlags.SCHEME_NORMALIZE);
                string? host = parsed.get_host ();
                string? ascii_host = host == null ? null : Hostname.to_ascii (host);
                if (ascii_host == null) return null;
                string display_host = Hostname.is_ip_address (ascii_host) &&
                    ascii_host.contains (":") ? "[" + ascii_host + "]" : ascii_host;
                int port = parsed.get_port ();
                return port == -1 || port == 443 ? "https://" + display_host.down () :
                    "https://%s:%d".printf (display_host.down (), port);
            } catch (UriError error) {
                return null;
            }
        }

        public static bool selected_paths_are_bounded (
                string[]? paths,
                bool select_multiple) {
            if (paths == null || paths.length == 0 ||
                    paths.length > MAX_SELECTED_FILES ||
                    (!select_multiple && paths.length != 1)) {
                return false;
            }
            int total_bytes = 0;
            var unique = new HashTable<string, bool> (str_hash, str_equal);
            foreach (string path in paths) {
                if (path.length == 0 || path.length > MAX_PATH_BYTES ||
                        !path.validate () || !Path.is_absolute (path) ||
                        contains_percent_escape (path) || unique.contains (path)) {
                    return false;
                }
                total_bytes += path.length;
                if (total_bytes > MAX_TOTAL_PATH_BYTES) return false;
                unique.insert (path, true);
            }
            return true;
        }

        static bool contains_percent_escape (string path) {
            for (int index = 0; index + 2 < path.length; index++) {
                if (path[index] == '%' && path[index + 1].isxdigit () &&
                        path[index + 2].isxdigit ()) {
                    return true;
                }
            }
            return false;
        }
    }
}
