/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class AddressResolver : Object {
        public const int MAX_WEB_URI_BYTES = PageDataPolicy.MAX_WEB_URI_BYTES;
        public const int MAX_EXTERNAL_URI_BYTES = 2048;
        const int MAX_SEARCH_INPUT_BYTES = 2048;

        public static bool is_safe_web_uri (string? input) {
            return PageDataPolicy.is_safe_web_uri (input);
        }

        public static bool is_safe_navigation_uri (string? input) {
            return (input != null && input.down () == "about:blank") ||
                is_safe_web_uri (input);
        }

        public static bool is_safe_secure_web_uri (string? input) {
            if (!is_safe_web_uri (input)) return false;
            try {
                return Uri.parse (input, UriFlags.SCHEME_NORMALIZE).get_scheme () == "https";
            } catch (UriError error) {
                return false;
            }
        }

        public static bool is_safe_host_name (string? input) {
            return input != null && input.length > 0 && input.length <= 1024 &&
                input.validate () && !contains_control_character (input) &&
                !contains_whitespace (input) && valid_host (input);
        }

        public static bool is_safe_external_uri (string? input) {
            if (input == null || input.length == 0 ||
                    input.length > MAX_EXTERNAL_URI_BYTES || !input.validate () ||
                    contains_control_character (input) || contains_whitespace (input) ||
                    input.contains ("\\")) {
                return false;
            }
            string? decoded = Uri.unescape_string (input);
            if (decoded == null || !decoded.validate () ||
                    contains_control_character (decoded) || contains_whitespace (decoded) ||
                    decoded.contains ("\\")) {
                return false;
            }
            string? scheme = Uri.parse_scheme (input);
            int separator = input.index_of_char (':');
            return scheme != null && separator > 0 && separator < input.length - 1 &&
                is_external_scheme (scheme.down ());
        }

        public static string resolve (string input, string search_template = "https://duckduckgo.com/?q=%s") {
            if (input.length > MAX_WEB_URI_BYTES || !input.validate () ||
                    contains_control_character (input))
                return "about:blank";
            string value = input.strip ();
            if (value == "") {
                return "about:blank";
            }
            if (is_safe_web_uri (value)) {
                return value;
            }
            if (!value.contains (" ") && !value.contains ("://") &&
                    (value == "localhost" || value.has_prefix ("localhost:") ||
                    value.contains ("."))) {
                string candidate = "https://" + value;
                if (is_safe_web_uri (candidate)) {
                    return candidate;
                }
            }
            if (Uri.parse_scheme (value) != null) return "about:blank";
            if (value.length > MAX_SEARCH_INPUT_BYTES || !value.validate () ||
                    contains_control_character (value)) {
                return "about:blank";
            }
            string search = search_template.replace (
                "%s", Uri.escape_string (value, null, true));
            return is_safe_web_uri (search) ? search : "about:blank";
        }

        static bool contains_control_character (string value) {
            int index = 0;
            unichar current;
            while (value.get_next_char (ref index, out current)) {
                if (current.iscntrl ()) return true;
            }
            return false;
        }

        static bool contains_whitespace (string value) {
            int index = 0;
            unichar current;
            while (value.get_next_char (ref index, out current)) {
                if (current.isspace ()) return true;
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

        static bool is_external_scheme (string scheme) {
            switch (scheme) {
                case "mailto":
                case "tel":
                case "sms":
                case "geo":
                case "maps":
                case "market":
                    return true;
                default:
                    return false;
            }
        }
    }
}
