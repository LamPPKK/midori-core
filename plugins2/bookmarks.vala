/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace XanhPlugins {
    public class Bookmarks : Peas.ExtensionBase, Xanh.BrowserPlugin {
        public Xanh.PluginHost host { owned get; construct set; }
        ulong handler;
        public void activate () {
            host.bookmarks_enabled = true;
            handler = host.bookmark_requested.connect ((tab) => {
                if (!tab.private_mode && Xanh.BrowserDatabase.is_web_uri (tab.uri)) {
                    try { host.database.add_bookmark (tab.uri, tab.title); }
                    catch (Error error) { warning ("Bookmark failed: %s", error.message); }
                }
            });
        }
        public void deactivate () {
            if (handler != 0) { host.disconnect (handler); handler = 0; }
            host.bookmarks_enabled = false;
        }
    }
}
[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (
        typeof (Xanh.BrowserPlugin), typeof (XanhPlugins.Bookmarks));
}
