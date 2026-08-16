/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class BrowserApplication : Gtk.Application {
        BrowserDatabase? database;

        public BrowserApplication () {
            Object (
                application_id: Config.APP_ID,
                flags: ApplicationFlags.HANDLES_OPEN
            );
        }

        protected override void startup () {
            base.startup ();
            set_accels_for_action ("win.new-tab", { "<Primary>t" });
            set_accels_for_action ("win.new-private-tab", { "<Primary><Shift>p" });
            set_accels_for_action ("win.close-tab", { "<Primary>w" });
        }

        protected override void activate () {
            open_window (null, true);
        }

        protected override void open (File[] files, string hint) {
            string? uri = files.length > 0 ? files[0].get_uri () : null;
            open_window (uri, false);
        }

        void open_window (string? uri, bool offer_import) {
            try {
                if (database == null) database = new BrowserDatabase ();
                var window = new BrowserWindow (this, database);
                window.restore_session_or_open (uri);
                window.present ();
                if (offer_import) window.offer_profile_import ();
            } catch (Error error) {
                critical ("Cannot start %s: %s", Config.APP_NAME, error.message);
                quit ();
            }
        }
    }
}
