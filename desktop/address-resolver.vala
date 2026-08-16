/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class AddressResolver : Object {
        public static string resolve (string input, string search_template = "https://duckduckgo.com/?q=%s") {
            string value = input.strip ();
            if (value == "") {
                return "about:blank";
            }
            if (BrowserDatabase.is_web_uri (value)) {
                return value;
            }
            if (!value.contains (" ") && (value == "localhost" || value.has_prefix ("localhost:") ||
                    value.contains ("."))) {
                string candidate = "https://" + value;
                if (BrowserDatabase.is_web_uri (candidate)) {
                    return candidate;
                }
            }
            return search_template.replace ("%s", Uri.escape_string (value, null, true));
        }
    }
}
