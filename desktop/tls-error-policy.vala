/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class TlsErrorPolicy : Object {
        public const int MAX_CERTIFICATE_NAME_BYTES = 1024;
        public const int MAX_CERTIFICATE_NAME_CHARACTERS = 256;

        public static bool is_prompt_context_current (
                string? failing_uri,
                string? current_uri,
                bool window_active,
                bool tab_active,
                bool process_stopped,
                bool clearing_data) {
            return window_active && tab_active && !process_stopped && !clearing_data &&
                failing_uri != null && failing_uri == current_uri &&
                AddressResolver.is_safe_secure_web_uri (failing_uri);
        }

        public static string? display_origin (string? failing_uri) {
            if (!AddressResolver.is_safe_secure_web_uri (failing_uri)) return null;
            try {
                var parsed = Uri.parse (failing_uri, UriFlags.SCHEME_NORMALIZE);
                string? host = parsed.get_host ();
                if (host == null) return null;
                string? ascii_host = Hostname.to_ascii (host);
                if (ascii_host == null) return null;
                string normalized_host = ascii_host.down ();
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

        public static string sanitize_certificate_name (string? value) {
            if (value == null || value == "" || !value.validate ()) return "Unknown";
            var builder = new StringBuilder.sized (
                int.min (value.length, MAX_CERTIFICATE_NAME_BYTES));
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
                    if (characters >= MAX_CERTIFICATE_NAME_CHARACTERS ||
                            builder.len + 1 > MAX_CERTIFICATE_NAME_BYTES) break;
                    builder.append_c (' ');
                    characters++;
                    pending_separator = false;
                }
                string encoded = character.to_string ();
                if (characters >= MAX_CERTIFICATE_NAME_CHARACTERS ||
                        builder.len + encoded.length > MAX_CERTIFICATE_NAME_BYTES) break;
                builder.append (encoded);
                characters++;
            }
            return builder.len == 0 ? "Unknown" : builder.str;
        }

        public static string describe_errors (TlsCertificateFlags errors) {
            var description = new StringBuilder ();
            append_error (description, errors, TlsCertificateFlags.UNKNOWN_CA,
                "unknown certificate authority");
            append_error (description, errors, TlsCertificateFlags.BAD_IDENTITY,
                "site identity mismatch");
            append_error (description, errors, TlsCertificateFlags.NOT_ACTIVATED,
                "certificate not active yet");
            append_error (description, errors, TlsCertificateFlags.EXPIRED,
                "certificate expired");
            append_error (description, errors, TlsCertificateFlags.REVOKED,
                "certificate revoked");
            append_error (description, errors, TlsCertificateFlags.INSECURE,
                "insecure certificate algorithm");
            append_error (description, errors, TlsCertificateFlags.GENERIC_ERROR,
                "certificate validation failed");
            return description.len == 0 ? "certificate validation failed" : description.str;
        }

        static void append_error (StringBuilder description,
                TlsCertificateFlags errors,
                TlsCertificateFlags flag,
                string label) {
            if ((errors & flag) == TlsCertificateFlags.NO_FLAGS) return;
            if (description.len > 0) description.append (", ");
            description.append (label);
        }
    }
}
