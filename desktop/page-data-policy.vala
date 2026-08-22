/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class PageDataPolicy : Object {
        public const int MAX_TITLE_BYTES = 4096;
        public const int MAX_WEB_URI_BYTES = 8192;

        public static bool is_safe_web_uri (string? value) {
            if (value == null || value.length == 0 ||
                    value.length > MAX_WEB_URI_BYTES || !value.validate () ||
                    contains_control_character (value) || contains_whitespace (value) ||
                    value.contains ("\\")) {
                return false;
            }
            string? decoded = Uri.unescape_string (value);
            if (decoded == null || !decoded.validate () ||
                    contains_control_character (decoded) || decoded.contains ("\\")) {
                return false;
            }
            try {
                var parsed = Uri.parse (value, UriFlags.SCHEME_NORMALIZE);
                string scheme = parsed.get_scheme ();
                string? host = parsed.get_host ();
                int port = parsed.get_port ();
                return (scheme == "http" || scheme == "https") &&
                    parsed.get_userinfo () == null && host != null &&
                    valid_host (host) &&
                    (port == -1 || (port > 0 && port <= 65535));
            } catch (UriError error) {
                return false;
            }
        }

        public static string sanitized_title (
                string? value,
                string? fallback = null) {
            string result = sanitized_candidate (value);
            if (result != "") return result;
            result = sanitized_candidate (fallback);
            return result != "" ? result : "Untitled";
        }

        static string sanitized_candidate (string? value) {
            if (value == null || !value.validate ()) return "";
            var builder = new StringBuilder.sized (
                int.min (value.length, MAX_TITLE_BYTES));
            bool pending_space = false;
            int index = 0;
            unichar character;
            while (value.get_next_char (ref index, out character)) {
                if (character.isspace ()) {
                    if (builder.len > 0) pending_space = true;
                    continue;
                }
                if (character.iscntrl () ||
                        character.type () == UnicodeType.FORMAT) continue;
                string encoded = character.to_string ();
                int separator_bytes = pending_space ? 1 : 0;
                if (builder.len + separator_bytes + encoded.length > MAX_TITLE_BYTES)
                    break;
                if (pending_space) builder.append_c (' ');
                builder.append (encoded);
                pending_space = false;
            }
            return builder.str;
        }

        static bool contains_control_character (string value) {
            int index = 0;
            unichar character;
            while (value.get_next_char (ref index, out character)) {
                if (character.iscntrl ()) return true;
            }
            return false;
        }

        static bool contains_whitespace (string value) {
            int index = 0;
            unichar character;
            while (value.get_next_char (ref index, out character)) {
                if (character.isspace ()) return true;
            }
            return false;
        }

        static bool valid_host (string value) {
            string? ascii_host = Hostname.to_ascii (value);
            if (ascii_host == null) return false;
            string ascii = ascii_host.down ();
            if (ascii == "" || ascii.length > 253 || ascii.has_prefix (".") ||
                    ascii.has_suffix (".")) {
                return false;
            }
            if (Hostname.is_ip_address (ascii)) return true;
            bool numeric_or_dot = true;
            for (int index = 0; index < ascii.length; index++) {
                char current = ascii[index];
                if (!(current.isdigit () || current == '.')) {
                    numeric_or_dot = false;
                    break;
                }
            }
            if (numeric_or_dot) return false;
            foreach (string label in ascii.split (".")) {
                if (label == "" || label.length > 63 || label.has_prefix ("-") ||
                        label.has_suffix ("-")) {
                    return false;
                }
                for (int index = 0; index < label.length; index++) {
                    char current = label[index];
                    if (!(current.isalnum () || current == '-')) return false;
                }
            }
            return true;
        }

    }
}
