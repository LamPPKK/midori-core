/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace XanhPlugins {
    public class ColorfulTabs : Peas.ExtensionBase, Xanh.BrowserPlugin {
        public Xanh.PluginHost host { owned get; construct set; }
        ulong handler;
        public void activate () {
            host.colorful_tabs_enabled = true;
            handler = host.page_loaded.connect ((tab) => {
                try {
                    var uri = Uri.parse (tab.uri, UriFlags.NONE);
                    string host_name = uri.get_host () ?? tab.uri;
                    string hash = Checksum.compute_for_string (ChecksumType.SHA256, host_name, -1);
                    tab.tint = "#" + hash.substring (0, 6);
                } catch (UriError error) {
                    tab.tint = null;
                }
            });
        }
        public void deactivate () {
            if (handler != 0) { host.disconnect (handler); handler = 0; }
            host.colorful_tabs_enabled = false;
        }
    }
}
[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (
        typeof (Xanh.BrowserPlugin), typeof (XanhPlugins.ColorfulTabs));
}
