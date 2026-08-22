/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class HttpAuthPolicy : Object {
        public const int MAX_REALM_BYTES = 1024;
        public const int MAX_REALM_CHARACTERS = 256;
        public const int MAX_USERNAME_BYTES = 1024;
        public const int MAX_USERNAME_CHARACTERS = 256;
        public const int MAX_PASSWORD_BYTES = 16384;
        public const int MAX_PASSWORD_CHARACTERS = 4096;

        public static bool is_prompt_context_current (
                string? requested_document_uri,
                string? current_document_uri,
                string? request_host,
                uint request_port,
                string? origin_protocol,
                string? origin_host,
                uint16 origin_port,
                bool supported_scheme,
                bool for_proxy,
                bool retry,
                bool window_active,
                bool tab_active,
                bool process_stopped,
                bool clearing_data) {
            if (!window_active || !tab_active || process_stopped || clearing_data ||
                    !supported_scheme || for_proxy || retry ||
                    requested_document_uri == null ||
                    requested_document_uri != current_document_uri ||
                    !AddressResolver.is_safe_secure_web_uri (requested_document_uri) ||
                    origin_protocol == null || origin_protocol.down () != "https" ||
                    !AddressResolver.is_safe_host_name (request_host) ||
                    !AddressResolver.is_safe_host_name (origin_host)) {
                return false;
            }
            try {
                var parsed = Uri.parse (requested_document_uri, UriFlags.SCHEME_NORMALIZE);
                string? document_host = normalize_host (parsed.get_host ());
                string? challenge_host = normalize_host (request_host);
                string? security_origin_host = normalize_host (origin_host);
                if (document_host == null || challenge_host == null ||
                        security_origin_host == null ||
                        document_host != challenge_host ||
                        document_host != security_origin_host) {
                    return false;
                }
                int document_port = parsed.get_port ();
                if (document_port == -1) document_port = 443;
                int challenge_port = request_port == 0 ? 443 : (int) request_port;
                int security_origin_port = origin_port == 0 ? 443 : (int) origin_port;
                return challenge_port == document_port &&
                    security_origin_port == document_port;
            } catch (UriError error) {
                return false;
            }
        }

        public static string? display_origin (string? document_uri) {
            if (!AddressResolver.is_safe_secure_web_uri (document_uri)) return null;
            try {
                var parsed = Uri.parse (document_uri, UriFlags.SCHEME_NORMALIZE);
                string? normalized_host = normalize_host (parsed.get_host ());
                if (normalized_host == null) return null;
                string display_host = Hostname.is_ip_address (normalized_host) &&
                    normalized_host.contains (":") ?
                    "[" + normalized_host + "]" : normalized_host;
                int port = parsed.get_port ();
                return port == -1 || port == 443 ? "https://" + display_host :
                    "https://%s:%d".printf (display_host, port);
            } catch (UriError error) {
                return null;
            }
        }

        public static string sanitize_realm (string? value) {
            if (value == null || value == "" || !value.validate ()) return "Protected area";
            var builder = new StringBuilder.sized (int.min (value.length, MAX_REALM_BYTES));
            int index = 0;
            int characters = 0;
            bool pending_separator = false;
            unichar character;
            while (value.get_next_char (ref index, out character)) {
                if (!character.isprint () || character.isspace ()) {
                    pending_separator = builder.len > 0;
                    continue;
                }
                if (pending_separator) {
                    if (characters >= MAX_REALM_CHARACTERS ||
                            builder.len + 1 > MAX_REALM_BYTES) break;
                    builder.append_c (' ');
                    characters++;
                    pending_separator = false;
                }
                string encoded = character.to_string ();
                if (characters >= MAX_REALM_CHARACTERS ||
                        builder.len + encoded.length > MAX_REALM_BYTES) break;
                builder.append (encoded);
                characters++;
            }
            return builder.len == 0 ? "Protected area" : builder.str;
        }

        public static bool credentials_are_bounded (string? username, string? password) {
            return username != null && password != null &&
                username.validate () && password.validate () &&
                username.length <= MAX_USERNAME_BYTES &&
                username.char_count () <= MAX_USERNAME_CHARACTERS &&
                password.length <= MAX_PASSWORD_BYTES &&
                password.char_count () <= MAX_PASSWORD_CHARACTERS;
        }

        static string? normalize_host (string? value) {
            if (value == null) return null;
            string? ascii = Hostname.to_ascii (value);
            return ascii == null ? null : ascii.down ();
        }
    }
}
