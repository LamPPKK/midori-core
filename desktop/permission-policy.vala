/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class PermissionPolicy : Object {
        public static bool is_prompt_context_current (
                string? requested_document_uri,
                string? current_document_uri,
                bool window_active,
                bool tab_active,
                bool process_stopped,
                bool clearing_data) {
            return window_active && tab_active && !process_stopped && !clearing_data &&
                requested_document_uri != null &&
                requested_document_uri == current_document_uri &&
                AddressResolver.is_safe_secure_web_uri (requested_document_uri);
        }

        public static bool storage_access_matches_document (
                string document_uri,
                string? current_domain,
                string? requesting_domain) {
            if (!AddressResolver.is_safe_secure_web_uri (document_uri) ||
                    !AddressResolver.is_safe_host_name (current_domain) ||
                    !AddressResolver.is_safe_host_name (requesting_domain)) {
                return false;
            }
            try {
                var parsed = Uri.parse (document_uri, UriFlags.SCHEME_NORMALIZE);
                string? document_host = normalize_host (parsed.get_host ());
                string? current_host = normalize_host (current_domain);
                string? requesting_host = normalize_host (requesting_domain);
                return document_host != null && current_host != null &&
                    requesting_host != null &&
                    host_is_same_or_subdomain (document_host, current_host) &&
                    !host_is_same_or_subdomain (requesting_host, current_host) &&
                    !host_is_same_or_subdomain (current_host, requesting_host);
            } catch (UriError error) {
                return false;
            }
        }

        public static string? display_origin (string? document_uri) {
            if (!AddressResolver.is_safe_secure_web_uri (document_uri)) return null;
            try {
                var parsed = Uri.parse (document_uri, UriFlags.SCHEME_NORMALIZE);
                string? host = parsed.get_host ();
                if (host == null) return null;
                string display_host = Hostname.is_ip_address (host) && host.contains (":") ?
                    "[" + host + "]" : host;
                int port = parsed.get_port ();
                return port == -1 || port == 443 ? "https://" + display_host :
                    "https://%s:%d".printf (display_host, port);
            } catch (UriError error) {
                return null;
            }
        }

        static string? normalize_host (string? value) {
            if (value == null) return null;
            string? ascii = Hostname.to_ascii (value);
            return ascii == null ? null : ascii.down ();
        }

        static bool host_is_same_or_subdomain (string host, string domain) {
            return host == domain || host.has_suffix ("." + domain);
        }
    }
}
