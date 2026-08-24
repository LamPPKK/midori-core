/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace Xanh {
    public errordomain AdblockSourceError {
        TOO_LARGE
    }

    public class AdblockSource {
        public const int MAX_FILTER_LIST_BYTES = 16 * 1024 * 1024;
        public const int MAX_FILTER_LINES = 500000;
        public const int MAX_FILTER_LINE_BYTES = 64 * 1024;
        public const int MAX_DOMAIN_LIST_BYTES = 256 * 1024;
        public const int MAX_DOMAINS = 1024;
        public const int MAX_DOMAIN_BYTES = 253;

        public static string[] normalized_domains (string configured) {
            try {
                return checked_normalized_domains (configured);
            } catch (AdblockSourceError error) {
                return {};
            }
        }

        public static string[] checked_normalized_domains (
                string configured) throws AdblockSourceError {
            if (configured.length > MAX_DOMAIN_LIST_BYTES)
                throw new AdblockSourceError.TOO_LARGE (
                    "Adblock domain configuration is too large");
            int entries = 1;
            for (int index = 0; index < configured.length; index++) {
                if (configured[index] == ',' && ++entries > MAX_DOMAINS)
                    throw new AdblockSourceError.TOO_LARGE (
                        "Adblock domain configuration contains too many entries");
            }

            string[] domains = {};
            var seen = new HashTable<string, bool> (str_hash, str_equal);
            foreach (string raw in configured.split (",")) {
                string domain = raw.strip ().down ();
                if (domain.has_prefix ("*.")) domain = domain.substring (2);
                if (domain == "" || domain.has_prefix (".") || domain.has_suffix (".") ||
                        domain.length > MAX_DOMAIN_BYTES || seen.contains (domain)) {
                    continue;
                }
                bool valid = true;
                int label_length = 0;
                for (int index = 0; index < domain.length; index++) {
                    char current = domain[index];
                    if (current == '.') {
                        if (label_length == 0 || label_length > 63 ||
                                domain[index - 1] == '-') {
                            valid = false;
                            break;
                        }
                        label_length = 0;
                    } else if (!(current.isalnum () || current == '-') ||
                            (label_length == 0 && current == '-')) {
                        valid = false;
                        break;
                    } else {
                        label_length++;
                    }
                }
                if (label_length == 0 || label_length > 63 ||
                        domain[domain.length - 1] == '-') valid = false;
                if (valid) {
                    seen.insert (domain, true);
                    domains += domain;
                }
            }
            return domains;
        }

        public static string native_filter_list (
                string configured,
                string blocked_domains,
                string whitelist_domains) throws AdblockSourceError {
            if (configured.length > MAX_FILTER_LIST_BYTES ||
                    blocked_domains.length > MAX_DOMAIN_LIST_BYTES ||
                    whitelist_domains.length > MAX_DOMAIN_LIST_BYTES) {
                throw new AdblockSourceError.TOO_LARGE ("Adblock configuration is too large");
            }

            string[] blocked = checked_normalized_domains (blocked_domains);
            var missing_rules = new HashTable<string, bool> (str_hash, str_equal);
            foreach (string domain in blocked)
                missing_rules.insert ("||%s^".printf (domain), true);
            mark_configured_rules_present (configured, missing_rules);

            var source = new StringBuilder ();
            if (configured != "") {
                source.append (configured);
                if (!configured.has_suffix ("\n")) source.append_c ('\n');
            }
            foreach (string domain in blocked) {
                string rule = "||%s^".printf (domain);
                if (missing_rules.contains (rule))
                    source.append (rule + "\n");
            }
            foreach (string domain in checked_normalized_domains (whitelist_domains))
                source.append ("@@*$domain=%s\n".printf (domain));

            string result = source.str;
            if (result.length > MAX_FILTER_LIST_BYTES)
                throw new AdblockSourceError.TOO_LARGE ("Adblock filter list is too large");
            return result;
        }

        static void mark_configured_rules_present (
                string configured,
                HashTable<string, bool> missing_rules) throws AdblockSourceError {
            int line_start = 0;
            int line_count = 0;
            for (int index = 0; index <= configured.length; index++) {
                if (index < configured.length && configured[index] != '\n') continue;
                if (index == configured.length && line_start == configured.length) break;
                int line_length = index - line_start;
                if (++line_count > MAX_FILTER_LINES ||
                        line_length > MAX_FILTER_LINE_BYTES) {
                    throw new AdblockSourceError.TOO_LARGE (
                        "Adblock filter list has too many or oversized lines");
                }
                string normalized = configured.substring (line_start, line_length).strip ();
                if (missing_rules.contains (normalized))
                    missing_rules.remove (normalized);
                line_start = index + 1;
            }
        }

        public static string legacy_webkit_json (
                string[] blocked,
                string[] allowed) {
            string whitelist = allowed.length > 0 ?
                ",\"unless-domain\":" + domain_json (allowed) : "";
            return ("[{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":%s%s}," +
                "\"action\":{\"type\":\"block\"}}]").printf (
                    domain_json (blocked), whitelist);
        }

        static string domain_json (string[] domains) {
            string json = "[";
            for (int index = 0; index < domains.length; index++) {
                if (index > 0) json += ",";
                json += "\"*" + domains[index] + "\"";
            }
            return json + "]";
        }
    }
}
