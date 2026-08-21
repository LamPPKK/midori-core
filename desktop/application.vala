/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class BrowserApplication : Gtk.Application {
        BrowserDatabase? database;
        SyncHost sync_host;
        uint sync_schedule_source;

        public BrowserApplication () {
            Object (
                application_id: Config.APP_ID,
                flags: ApplicationFlags.HANDLES_OPEN
            );
            sync_host = new SyncHost (Path.build_filename (
                Environment.get_user_data_dir (), "xanh-browser", "firefox-sync"));
        }

        protected override void startup () {
            base.startup ();
            set_accels_for_action ("win.new-tab", { "<Primary>t" });
            set_accels_for_action ("win.new-private-tab", { "<Primary><Shift>p" });
            set_accels_for_action ("win.close-tab", { "<Primary>w" });
            if (sync_host.is_configured ()) initialize_sync.begin ();
        }

        protected override void activate () {
            open_window (null, true);
        }

        protected override void open (File[] files, string hint) {
            string? uri = files.length > 0 ? files[0].get_uri () : null;
            if (uri != null && sync_host.is_redirect_uri (uri)) {
                complete_sync_redirect.begin (uri);
                return;
            }
            open_window (uri, false);
        }

        protected override void shutdown () {
            if (sync_schedule_source != 0) {
                Source.remove (sync_schedule_source);
                sync_schedule_source = 0;
            }
            if (sync_host.vault_unlocked ()) {
                try { sync_host.lock_vault (); }
                catch (Error error) { warning ("Cannot lock Firefox Sync vault: %s", error.message); }
            }
            base.shutdown ();
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

        async void initialize_sync () {
            try {
                yield sync_host.initialize_async ();
                maybe_sync (SyncReason.STARTUP);
                ensure_sync_schedule ();
            } catch (Error error) {
                warning ("Firefox Sync host initialization failed: %s", error.message);
            }
        }

        void ensure_sync_schedule () {
            if (sync_schedule_source != 0) return;
            sync_schedule_source = Timeout.add_seconds (30, () => {
                maybe_sync (sync_host.sync_due (SyncReason.LOCAL_CHANGE, 0)
                    ? SyncReason.LOCAL_CHANGE : SyncReason.SCHEDULED);
                return Source.CONTINUE;
            });
        }

        void maybe_sync (SyncReason reason) {
            if (!sync_host.sync_due (reason, 0)) return;
            sync_host.sync_async.begin (reason, null, (object, result) => {
                try { sync_host.sync_async.end (result); }
                catch (Error error) { warning ("Firefox Sync failed: %s", error.message); }
            });
        }

        async void complete_sync_redirect (string uri) {
            try {
                if (!sync_host.is_ready ()) yield sync_host.initialize_async ();
                ensure_sync_schedule ();
                if (!(yield sync_host.complete_redirect_async (uri))) {
                    throw new IOError.FAILED ("Firefox Account did not reach connected state");
                }
                show_sync_message ("Firefox Sync connected",
                    "Xanh Browser is now connected. The first merge runs without opening remote tabs.");
                maybe_sync (SyncReason.MANUAL);
            } catch (Error error) {
                show_sync_message ("Firefox Sync sign-in failed", error.message);
            }
        }

        public void show_sync_settings (Gtk.Window parent) {
            show_sync_settings_async.begin (parent);
        }

        async void show_sync_settings_async (Gtk.Window parent) {
            try {
                if (!sync_host.is_configured ()) {
                    show_sync_message ("Firefox Sync unavailable", sync_host.dup_status () ??
                        "This build has no approved account configuration.", parent);
                    return;
                }
                if (!sync_host.is_ready ()) yield sync_host.initialize_async ();
                ensure_sync_schedule ();
                int state = sync_host.account_state ();
                if (state == 0) {
                    string domain = sync_host.dup_account_domain () ?? "the configured Accounts server";
                    var confirm = new Gtk.AlertDialog ("Connect Firefox Sync?");
                    confirm.detail = "Xanh Browser will open the system browser and connect to %s."
                        .printf (domain);
                    confirm.buttons = { "Cancel", "Continue" };
                    confirm.cancel_button = 0;
                    confirm.default_button = 0;
                    if ((yield confirm.choose (parent, null)) != 1) return;
                    string oauth_url = yield sync_host.begin_oauth_async ();
                    var launcher = new Gtk.UriLauncher (oauth_url);
                    yield launcher.launch (parent, null);
                    return;
                }
                if (state == 1) {
                    show_sync_message ("Firefox Sync sign-in",
                        "Complete sign-in in the system browser, then return to Xanh Browser.", parent);
                    return;
                }
                if (state == 3) {
                    var attention = new Gtk.AlertDialog ("Firefox Account needs attention");
                    attention.detail = sync_host.dup_status () ??
                        "Disconnect this account before reconnecting.";
                    attention.buttons = { "Cancel", "Disconnect" };
                    attention.cancel_button = 0;
                    attention.default_button = 0;
                    if ((yield attention.choose (parent, null)) == 1)
                        yield confirm_disconnect (parent);
                    return;
                }

                var actions = new Gtk.AlertDialog ("Firefox Sync");
                actions.detail = sync_host.dup_status () ?? "Connected";
                actions.buttons = { "Cancel", "Sync Now",
                    sync_host.vault_unlocked () ? "Lock Password Vault" : "Unlock Password Vault",
                    "Disconnect" };
                actions.cancel_button = 0;
                actions.default_button = 0;
                int selected = yield actions.choose (parent, null);
                if (selected == 1) {
                    yield sync_host.sync_async (SyncReason.MANUAL);
                    show_sync_message ("Firefox Sync", sync_host.dup_status () ?? "Sync complete", parent);
                } else if (selected == 2) {
                    if (sync_host.vault_unlocked ()) sync_host.lock_vault ();
                    else yield sync_host.unlock_vault_async ();
                    show_sync_message ("Password vault", sync_host.dup_status () ??
                        (sync_host.vault_unlocked () ? "Unlocked" : "Locked"), parent);
                } else if (selected == 3) {
                    yield confirm_disconnect (parent);
                }
            } catch (Error error) {
                show_sync_message ("Firefox Sync", error.message, parent);
            }
        }

        async void confirm_disconnect (Gtk.Window parent) throws Error {
            var dialog = new Gtk.AlertDialog ("Disconnect Firefox Sync?");
            dialog.detail = "Keep local browser data by default, or remove local Sync databases and the device key.";
            dialog.buttons = { "Cancel", "Keep Local Data", "Remove from This Device" };
            dialog.cancel_button = 0;
            dialog.default_button = 0;
            int selected = yield dialog.choose (parent, null);
            if (selected == 1 || selected == 2) {
                yield sync_host.disconnect_async (selected == 2);
                show_sync_message ("Firefox Sync disconnected", sync_host.dup_status () ??
                    "Local data kept", parent);
            }
        }

        public void lock_sync_vault () {
            if (!sync_host.vault_unlocked ()) return;
            try { sync_host.lock_vault (); }
            catch (Error error) { warning ("Cannot lock Firefox Sync vault: %s", error.message); }
        }

        public void window_closing () {
            if (get_windows ().length () != 1 ||
                !sync_host.sync_due (SyncReason.PRE_SLEEP, 0)) {
                lock_sync_vault ();
                return;
            }
            hold ();
            sync_host.sync_async.begin (SyncReason.PRE_SLEEP, null, (object, result) => {
                try { sync_host.sync_async.end (result); }
                catch (Error error) { warning ("Pre-sleep Firefox Sync failed: %s", error.message); }
                lock_sync_vault ();
                release ();
            });
        }

        void show_sync_message (string title, string detail, Gtk.Window? parent = null) {
            var dialog = new Gtk.AlertDialog (title);
            dialog.detail = detail;
            dialog.buttons = { "OK" };
            dialog.show (parent ?? active_window);
        }
    }
}
