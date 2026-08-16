/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class PluginManager : Object {
        Peas.Engine engine;
        Peas.ExtensionSet extension_set;

        public PluginManager (PluginHost host, string? development_path = null) {
            engine = new Peas.Engine ();
            if (development_path != null) {
                engine.add_search_path (development_path, development_path);
            }
            engine.add_search_path (Config.plugin_dir (), Config.plugin_dir ());
            engine.add_search_path ("/app/lib/xanh-browser", "/app/lib/xanh-browser");

            Value host_value = Value (typeof (PluginHost));
            host_value.set_object (host);
            string[] names = { "host" };
            Value[] values = { host_value };
            extension_set = new Peas.ExtensionSet.with_properties (
                engine, typeof (BrowserPlugin), names, values);
            extension_set.extension_added.connect ((info, extension) => {
                ((BrowserPlugin) extension).activate ();
            });
            extension_set.extension_removed.connect ((info, extension) => {
                ((BrowserPlugin) extension).deactivate ();
            });

            string[] modules = {
                "xanh-adblock", "xanh-bookmarks", "xanh-session",
                "xanh-colorful-tabs", "xanh-status-clock", "xanh-status-features"
            };
            foreach (string module in modules) {
                unowned Peas.PluginInfo? info = engine.get_plugin_info (module);
                if (info == null) {
                    warning ("Native plugin is unavailable: %s", module);
                    continue;
                }
                engine.load_plugin (info);
            }
        }

        public void shutdown () {
            string[] loaded = engine.dup_loaded_plugins ();
            foreach (string module in loaded) {
                unowned Peas.PluginInfo? info = engine.get_plugin_info (module);
                if (info != null) {
                    engine.unload_plugin (info);
                }
            }
            engine.garbage_collect ();
        }
    }
}
