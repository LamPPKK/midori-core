/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace XanhPlugins {
    public class Adblock : Peas.ExtensionBase, Xanh.BrowserPlugin {
        public Xanh.PluginHost host { owned get; construct set; }
        public void activate () {
            host.adblock_blocked_domains = setting (
                "adblock-blocked-domains",
                "doubleclick.net,googlesyndication.com,google-analytics.com,facebook.net");
            host.adblock_whitelist_domains = setting ("adblock-whitelist-domains", "");
            host.adblock_enabled = true;
        }
        public void deactivate () { host.adblock_enabled = false; }

        string setting (string key, string fallback) {
            try { return host.database.get_setting (key) ?? fallback; }
            catch (Error error) { return fallback; }
        }
    }
}
[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (
        typeof (Xanh.BrowserPlugin), typeof (XanhPlugins.Adblock));
}
