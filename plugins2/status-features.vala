/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace XanhPlugins {
    public class StatusFeatures : Peas.ExtensionBase, Xanh.BrowserPlugin {
        public Xanh.PluginHost host { owned get; construct set; }
        ulong handler;
        public void activate () {
            host.status_features_enabled = true;
            handler = host.progress_changed.connect ((tab) => {
                if (tab.progress < 1.0) {
                    host.status_text = "Loading %.0f%%".printf (tab.progress * 100.0);
                } else {
                    host.status_text = "";
                }
            });
        }
        public void deactivate () {
            if (handler != 0) { host.disconnect (handler); handler = 0; }
            host.status_features_enabled = false;
        }
    }
}
[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (
        typeof (Xanh.BrowserPlugin), typeof (XanhPlugins.StatusFeatures));
}
