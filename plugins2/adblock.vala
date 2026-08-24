/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace XanhPlugins {
    public class Adblock : Peas.ExtensionBase, Xanh.BrowserPlugin {
        const int MAX_FILTER_LIST_BYTES = 16 * 1024 * 1024;
        const string BASELINE_FILTER_LIST =
            "||doubleclick.net^\n" +
            "||googlesyndication.com^\n" +
            "||google-analytics.com^\n" +
            "||adservice.google.com^\n" +
            "||amazon-adsystem.com^\n" +
            "||scorecardresearch.com^\n" +
            "||connect.facebook.net^$third-party\n";
        const string BASELINE_DOMAINS =
            "doubleclick.net,googlesyndication.com,google-analytics.com," +
            "adservice.google.com,amazon-adsystem.com,scorecardresearch.com";
        public Xanh.PluginHost host { owned get; construct set; }
        public void activate () {
            host.adblock_filter_list = bounded_filter_setting (
                "adblock-filter-list", BASELINE_FILTER_LIST);
            host.adblock_blocked_domains = setting (
                "adblock-blocked-domains", BASELINE_DOMAINS);
            host.adblock_whitelist_domains = setting ("adblock-whitelist-domains", "");
            host.adblock_enabled = enabled_setting ("adblock-enabled", true);
        }
        public void deactivate () { host.adblock_enabled = false; }

        string setting (string key, string fallback) {
            try { return host.database.get_setting (key) ?? fallback; }
            catch (Error error) { return fallback; }
        }

        bool enabled_setting (string key, bool fallback) {
            string value = setting (key, fallback ? "true" : "false");
            return value.down () == "true" || value == "1" || value.down () == "yes";
        }

        string bounded_filter_setting (string key, string fallback) {
            string value = setting (key, fallback);
            return value.length <= MAX_FILTER_LIST_BYTES ? value : "";
        }
    }
}
[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (
        typeof (Xanh.BrowserPlugin), typeof (XanhPlugins.Adblock));
}
