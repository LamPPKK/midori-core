/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace XanhPlugins {
    public class StatusClock : Peas.ExtensionBase, Xanh.BrowserPlugin {
        public Xanh.PluginHost host { owned get; construct set; }
        uint timer;
        public void activate () {
            host.status_clock_enabled = true;
            timer = Timeout.add_seconds (1, () => {
                host.status_text = new DateTime.now_local ().format ("%H:%M");
                return Source.CONTINUE;
            });
        }
        public void deactivate () {
            if (timer != 0) { Source.remove (timer); timer = 0; }
            host.status_clock_enabled = false;
        }
    }
}
[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (
        typeof (Xanh.BrowserPlugin), typeof (XanhPlugins.StatusClock));
}
