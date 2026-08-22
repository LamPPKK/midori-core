/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class BrowserApplication : Gtk.Application {
        BrowserDatabase? database;
        SyncHost sync_host;
        SyncDataCoordinator? sync_data;
        uint sync_schedule_source;
        bool places_mirror_ready;
        bool browsing_data_clear_in_progress;
        bool sync_workflow_running;
        bool pending_window_open;
        string? pending_window_uri;
        bool pending_window_offer_import;
        bool device_data_reset_applied;
        bool device_removal_resume_running;

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
            if (browsing_data_clear_in_progress) {
                pending_window_open = true;
                pending_window_uri = uri;
                pending_window_offer_import = pending_window_offer_import || offer_import;
                return;
            }
            try {
                var window = new BrowserWindow (this, ensure_database ());
                window.restore_session_or_open (uri);
                window.present ();
                if (offer_import) window.offer_profile_import ();
            } catch (Error error) {
                critical ("Cannot start %s: %s", Config.APP_NAME, error.message);
                quit ();
            }
        }

        BrowserDatabase ensure_database () throws DatabaseError {
            if (database == null) {
                database = new BrowserDatabase ();
                places_mirror_ready = database.get_marker ("places_mirror_v1_ready");
            }
            if (sync_data == null) sync_data = new SyncDataCoordinator (database, sync_host);
            apply_pending_device_data_reset ();
            if (database.get_marker ("places_snapshot_clear_pending")) {
                try {
                    sync_data.clear_migration_snapshots ();
                    database.clear_marker ("places_snapshot_clear_pending");
                } catch (Error error) {
                    warning ("Cannot retry migration snapshot cleanup: %s", error.message);
                }
            }
            return database;
        }

        File device_data_reset_marker () {
            return File.new_for_path (Path.build_filename (
                Environment.get_user_data_dir (), "xanh-browser",
                "sync-device-data-reset-pending"));
        }

        bool device_removal_pending () {
            return device_data_reset_applied ||
                device_data_reset_marker ().query_exists ();
        }

        bool history_clear_pending () {
            try {
                return ensure_database ().get_marker ("places_history_clear_pending");
            } catch (Error error) {
                warning ("Cannot inspect pending history deletion: %s", error.message);
                return true;
            }
        }

        void persist_device_data_reset_intent () throws Error {
            var marker = device_data_reset_marker ();
            SyncHost.write_durable_marker (marker.get_path ());
            device_data_reset_applied = false;
        }

        void apply_pending_device_data_reset () throws DatabaseError {
            if (device_data_reset_applied || !device_data_reset_marker ().query_exists ()) return;
            // Keep both recovery intents durable until the compatibility mirror
            // and every immutable migration snapshot have been removed.
            database.set_marker ("places_snapshot_clear_pending");
            database.reset_sync_local_data ();
            places_mirror_ready = false;
            device_data_reset_applied = true;
            try {
                sync_data.clear_migration_snapshots ();
                database.clear_marker ("places_snapshot_clear_pending");
            } catch (Error error) {
                warning ("Cannot finish pending device-data cleanup; it will retry: %s",
                    error.message);
            }
        }

        void finish_device_data_reset_marker () throws Error {
            if (!device_data_reset_applied) return;
            SyncHost.remove_durable_marker (device_data_reset_marker ().get_path ());
            device_data_reset_applied = false;
        }

        async void initialize_sync () {
            try {
                yield sync_host.initialize_async ();
                yield resume_pending_device_removal ();
                ensure_sync_schedule ();
                yield apply_pending_history_clear ();
                if (sync_host.account_state () == 2)
                    yield prepare_connected_data_singleflight ();
                maybe_sync (SyncReason.STARTUP);
            } catch (Error error) {
                warning ("Firefox Sync host initialization failed: %s", error.message);
            }
        }

        async void resume_pending_device_removal () throws Error {
            while (device_removal_resume_running) {
                SourceFunc resume = resume_pending_device_removal.callback;
                Timeout.add (10, () => {
                    resume ();
                    return Source.REMOVE;
                });
                yield;
            }
            if (!device_removal_pending ()) {
                if (!sync_host.is_ready ()) yield sync_host.initialize_async ();
                return;
            }
            device_removal_resume_running = true;
            try {
                // The application marker spans the native and compatibility-
                // data phases. Repeating native delete is safe and closes a
                // crash gap before the host worker could persist its marker.
                if (!sync_host.is_ready ()) yield sync_host.initialize_async ();
                yield sync_host.disconnect_async (true);
                ensure_database ();
                if (database.get_marker ("places_snapshot_clear_pending")) {
                    throw new IOError.FAILED (
                        "Migration snapshot removal is still pending");
                }
                // Reopen a clean disconnected runtime before acknowledging the
                // application marker so Settings can start OAuth in one pass.
                yield sync_host.initialize_async ();
                finish_device_data_reset_marker ();
            } finally {
                device_removal_resume_running = false;
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
            if (device_removal_pending () || history_clear_pending ()) return;
            if (!sync_host.sync_due (reason, 0)) return;
            run_sync.begin (reason, (object, result) => {
                try { run_sync.end (result); }
                catch (Error error) { warning ("Firefox Sync failed: %s", error.message); }
            });
        }

        async string run_sync (SyncReason reason) throws Error {
            if (sync_workflow_running)
                throw new IOError.BUSY ("A Firefox Sync workflow is already running");
            sync_workflow_running = true;
            try {
                require_sync_allowed ();
                yield prepare_connected_data ();
                require_sync_allowed ();
                yield update_local_tabs ();
                require_sync_allowed ();
                string result = yield sync_host.sync_async (reason);
                require_sync_allowed ();
                if (sync_data != null) {
                    yield sync_data.refresh_compatibility_mirror ();
                    require_sync_allowed ();
                    places_mirror_ready = true;
                }
                return result;
            } finally {
                sync_workflow_running = false;
            }
        }

        async void prepare_connected_data_singleflight () throws Error {
            if (sync_workflow_running)
                throw new IOError.BUSY ("A Firefox Sync workflow is already running");
            sync_workflow_running = true;
            try {
                yield prepare_connected_data ();
            } finally {
                sync_workflow_running = false;
            }
        }

        async void prepare_connected_data () throws Error {
            require_no_browsing_data_clear ();
            if (sync_host.account_state () != 2) return;
            ensure_database ();
            if (sync_data != null) {
                if (database.get_marker ("places_history_clear_pending")) {
                    yield apply_pending_history_clear ();
                }
                yield sync_data.migrate_once ();
                require_no_browsing_data_clear ();
                if (!places_mirror_ready) {
                    yield sync_data.refresh_compatibility_mirror ();
                    require_no_browsing_data_clear ();
                    places_mirror_ready = true;
                }
            }
        }

        async void update_local_tabs () throws Error {
            var builder = new Json.Builder ();
            builder.begin_array ();
            int remaining = BrowserWindow.MAX_SYNC_TABS;
            foreach (var window in get_windows ()) {
                var browser = window as BrowserWindow;
                if (browser != null && remaining > 0)
                    remaining -= browser.append_sync_tabs (builder, remaining);
            }
            builder.end_array ();
            var generator = new Json.Generator ();
            generator.root = builder.get_root ();
            yield sync_host.update_local_tabs_async (generator.to_data (null));
        }

        async void complete_sync_redirect (string uri) {
            try {
                if (!sync_host.is_ready ()) yield sync_host.initialize_async ();
                yield resume_pending_device_removal ();
                ensure_sync_schedule ();
                if (!(yield sync_host.complete_redirect_async (uri))) {
                    throw new IOError.FAILED ("Firefox Account did not reach connected state");
                }
                show_sync_message ("Firefox Sync connected",
                    "Xanh Browser is now connected. The first merge runs without opening remote tabs.");
                yield run_sync (SyncReason.MANUAL);
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
                yield resume_pending_device_removal ();
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
                    yield run_sync (SyncReason.MANUAL);
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
                if (selected == 1) {
                    yield sync_host.disconnect_async (false);
                } else {
                    if (!begin_browsing_data_clear ()) {
                        throw new IOError.BUSY (
                            "Clear Browsing Data or device-data removal is already running");
                    }
                    try {
                        ensure_database ();
                        if (sync_data != null) yield sync_data.quiesce_migrations ();
                        // This write-ahead marker covers native/Secret Service,
                        // compatibility-database and snapshot cleanup as one
                        // restart-safe user intent.
                        persist_device_data_reset_intent ();
                        yield sync_host.disconnect_async (true);
                        string? cleanup_warning = null;
                        try { clear_sync_migration_snapshots (); }
                        catch (Error error) { cleanup_warning = error.message; }
                        try {
                            database.reset_sync_local_data ();
                        } catch (Error error) {
                            throw new IOError.FAILED (
                                "Account data was removed, but local browser metadata could " +
                                "not be reset; the reset will retry at startup: " + error.message);
                        }
                        places_mirror_ready = false;
                        device_data_reset_applied = true;
                        if (cleanup_warning == null &&
                                !database.get_marker ("places_snapshot_clear_pending")) {
                            finish_device_data_reset_marker ();
                        }
                        if (cleanup_warning != null) {
                            throw new IOError.FAILED (
                                "Account data was removed, but migration snapshot cleanup " +
                                "remains pending: " + cleanup_warning);
                        }
                    } finally {
                        finish_browsing_data_clear ();
                    }
                }
                show_sync_message ("Firefox Sync disconnected", sync_host.dup_status () ??
                    "Local data kept", parent);
            }
        }

        public void lock_sync_vault () {
            if (!sync_host.vault_unlocked ()) return;
            try { sync_host.lock_vault (); }
            catch (Error error) { warning ("Cannot lock Firefox Sync vault: %s", error.message); }
        }

        public bool sync_connected () {
            return !device_removal_pending () &&
                sync_host.is_ready () && sync_host.account_state () == 2;
        }

        public bool synced_places_available () {
            return places_mirror_ready;
        }

        public bool begin_browsing_data_clear () {
            if (browsing_data_clear_in_progress) return false;
            browsing_data_clear_in_progress = true;
            sync_data?.cancel_migrations_for_history_clear ();
            return true;
        }

        public void finish_browsing_data_clear () {
            browsing_data_clear_in_progress = false;
            if (pending_window_open) {
                string? uri = pending_window_uri;
                bool offer_import = pending_window_offer_import;
                pending_window_open = false;
                pending_window_uri = null;
                pending_window_offer_import = false;
                open_window (uri, offer_import);
            }
        }

        public bool is_browsing_data_clear_in_progress () {
            return browsing_data_clear_in_progress;
        }

        void require_no_browsing_data_clear () throws IOError {
            if (browsing_data_clear_in_progress) {
                throw new IOError.BUSY ("Clear Browsing Data is in progress");
            }
        }

        void require_sync_allowed () throws IOError {
            require_no_browsing_data_clear ();
            if (device_removal_pending () || history_clear_pending ()) {
                throw new IOError.BUSY (
                    "Destructive browser-data cleanup is pending recovery");
            }
        }

        public void import_new_legacy_data () {
            import_new_legacy_data_async.begin ();
        }

        async void import_new_legacy_data_async () {
            try {
                ensure_database ();
                if (!sync_connected () || browsing_data_clear_in_progress) {
                    database.invalidate_sync_migration ();
                    database.clear_marker ("places_mirror_v1_ready");
                    places_mirror_ready = false;
                    return;
                }
                if (sync_data != null) {
                    // ProfileImporter has already committed its own marker. Clear
                    // the Places marker before the first await so a crash or
                    // partial native import is retried on the next startup.
                    database.invalidate_sync_migration ();
                    database.clear_marker ("places_mirror_v1_ready");
                    places_mirror_ready = false;
                    yield sync_data.import_new_legacy_data ();
                    yield sync_data.refresh_compatibility_mirror ();
                    places_mirror_ready = true;
                }
                maybe_sync (SyncReason.LOCAL_CHANGE);
            } catch (Error error) {
                warning ("Cannot migrate newly imported legacy data to Places: %s", error.message);
            }
        }

        public void save_synced_bookmark (TabState state) {
            if (state.private_mode || !BrowserDatabase.is_web_uri (state.uri)) return;
            save_synced_bookmark_async.begin (state.uri, state.title);
        }

        async void save_synced_bookmark_async (string uri, string title) {
            try {
                ensure_database ();
                if (!sync_connected ()) {
                    retain_offline_bookmark (uri, title);
                    return;
                }
                if (sync_data != null) yield sync_data.save_bookmark (uri, title);
            } catch (SyncHostError.HISTORY_CLEARED error) {
                return;
            } catch (Error error) {
                try { retain_offline_bookmark (uri, title); }
                catch (Error fallback_error) {
                    warning ("Cannot retain the bookmark for a later Sync: %s",
                        fallback_error.message);
                }
                warning ("Cannot save bookmark to Places: %s", error.message);
            }
        }

        void retain_offline_bookmark (string uri, string title) throws DatabaseError {
            // The legacy row was already written by BrowserWindow. Always
            // invalidate the completed import even when no compatibility
            // mirror exists yet, otherwise reconnect would skip this change.
            database.invalidate_sync_migration ();
            if (!places_mirror_ready) return;
            database.upsert_places_bookmark (new StoredPage (
                uri, title, new DateTime.now_utc ().to_unix ()));
        }

        public void record_synced_history (TabState state) {
            if (state.private_mode || !BrowserDatabase.is_web_uri (state.uri)) return;
            record_synced_history_async.begin (state.uri, state.title);
        }

        async void record_synced_history_async (string uri, string title) {
            try {
                ensure_database ();
                if (!sync_connected ()) {
                    retain_offline_history (uri, title);
                    return;
                }
                if (sync_data != null) yield sync_data.record_history (uri, title, false);
            } catch (SyncHostError.HISTORY_CLEARED error) {
                // Clear Browsing Data invalidates mutations that were queued
                // before the clear. Do not reintroduce them into the mirror.
                return;
            } catch (Error error) {
                try { retain_offline_history (uri, title); }
                catch (Error fallback_error) {
                    warning ("Cannot retain history for a later Sync: %s",
                        fallback_error.message);
                }
                warning ("Cannot save history to Places: %s", error.message);
            }
        }

        void retain_offline_history (string uri, string title) throws DatabaseError {
            database.invalidate_sync_migration ();
            if (!places_mirror_ready) return;
            database.append_places_history (new StoredPage (
                uri, title, new DateTime.now_utc ().to_unix ()));
        }

        public async List<RemoteTabsDevice> get_remote_tabs () throws Error {
            if (!sync_connected ()) {
                throw new IOError.NOT_CONNECTED ("Firefox Sync is not connected");
            }
            ensure_database ();
            return yield sync_data.remote_tabs ();
        }

        public async string get_sync_credentials (
                string document_url, string origin,
                Cancellable? cancellable = null) throws Error {
            require_sync_allowed ();
            if (!sync_connected ()) {
                throw new IOError.NOT_CONNECTED ("Firefox Sync is not connected");
            }
            if (!sync_host.vault_unlocked ()) {
                if (!(yield sync_host.unlock_vault_async (cancellable))) {
                    throw new IOError.PERMISSION_DENIED (
                        "The Firefox Sync password vault remains locked");
                }
            }
            require_sync_allowed ();
            string context = credential_context_json (document_url, origin);
            string result = yield sync_host.credentials_json_async (context, cancellable);
            require_sync_allowed ();
            if (!sync_host.vault_unlocked ()) {
                throw new IOError.PERMISSION_DENIED (
                    "The Firefox Sync password vault locked during the request");
            }
            return result;
        }

        public async void touch_sync_credential (
                string credential_id, string document_url, string origin,
                Cancellable? cancellable = null) throws Error {
            require_sync_allowed ();
            if (!sync_connected () || !sync_host.vault_unlocked ()) {
                throw new IOError.PERMISSION_DENIED (
                    "The Firefox Sync password vault is unavailable");
            }
            if (credential_id.length == 0 || credential_id.length > 128) {
                throw new IOError.INVALID_ARGUMENT ("The selected credential ID is invalid");
            }
            string context = credential_context_json (document_url, origin);
            if (!(yield sync_host.touch_credential_async (
                    credential_id, context, cancellable))) {
                throw new IOError.FAILED ("The selected credential could not be updated");
            }
            require_sync_allowed ();
        }

        string credential_context_json (string document_url, string origin) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("document_url");
            builder.add_string_value (document_url);
            builder.set_member_name ("top_frame_origin");
            builder.add_string_value (origin);
            builder.set_member_name ("frame_origin");
            builder.add_string_value (origin);
            builder.set_member_name ("is_private");
            builder.add_boolean_value (false);
            builder.set_member_name ("user_selected");
            builder.add_boolean_value (true);
            builder.end_object ();
            var generator = new Json.Generator ();
            generator.root = builder.get_root ();
            return generator.to_data (null);
        }

        public async void clear_synced_history () throws Error {
            ensure_database ();
            bool has_places_history = places_mirror_ready ||
                database.get_marker ("places_migration_v1_complete") ||
                database.get_marker ("places_history_clear_pending");
            if (!has_places_history && !sync_host.is_ready () &&
                    !sync_host.is_configured ()) return;

            // Write the intent before initialization/native work so a hard
            // process stop cannot make a confirmed deletion disappear.
            database.set_marker ("places_history_clear_pending");
            if (!sync_host.is_ready ()) {
                if (!sync_host.is_configured ()) {
                    throw new IOError.NOT_INITIALIZED (
                        "Firefox Sync storage is unavailable in this build");
                }
                yield sync_host.initialize_async ();
            }
            yield apply_pending_history_clear (true);
        }

        public void clear_sync_migration_snapshots () throws Error {
            ensure_database ();
            // Snapshot deletion is also write-ahead: only a successful prune
            // may clear this marker.
            database.set_marker ("places_snapshot_clear_pending");
            try {
                if (sync_data != null) sync_data.clear_migration_snapshots ();
                database.clear_marker ("places_snapshot_clear_pending");
            } catch (Error error) {
                throw error;
            }
        }

        async void apply_pending_history_clear (bool force = false) throws Error {
            ensure_database ();
            if (!force && !database.get_marker ("places_history_clear_pending")) return;
            if (!sync_host.is_ready () || sync_data == null) {
                throw new IOError.NOT_INITIALIZED (
                    "Firefox Sync storage is not ready; its history deletion remains pending");
            }
            sync_data.cancel_migrations_for_history_clear ();
            yield sync_data.quiesce_migrations ();
            yield sync_data.clear_history ();
            // Keep the write-ahead history marker until every local source
            // capable of reimporting visits has also been removed.
            database.clear_private_data ();
            clear_sync_migration_snapshots ();
            places_mirror_ready = false;
            database.clear_marker ("places_history_clear_pending");
        }

        public void window_closing () {
            if (get_windows ().length () != 1 ||
                !sync_host.sync_due (SyncReason.PRE_SLEEP, 0)) {
                lock_sync_vault ();
                return;
            }
            hold ();
            run_sync.begin (SyncReason.PRE_SLEEP, (object, result) => {
                try { run_sync.end (result); }
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
