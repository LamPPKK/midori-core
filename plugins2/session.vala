/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace XanhPlugins {
    public class Session : Peas.ExtensionBase, Xanh.BrowserPlugin {
        public Xanh.PluginHost host { owned get; construct set; }
        public void activate () { host.session_enabled = true; }
        public void deactivate () { host.session_enabled = false; }
    }
}
[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (
        typeof (Xanh.BrowserPlugin), typeof (XanhPlugins.Session));
}
