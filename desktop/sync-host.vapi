/* SPDX-License-Identifier: LGPL-2.1-or-later */
[CCode (cheader_filename = "sync-host.h")]
namespace Xanh {
    [CCode (cname = "XanhSyncHostError", cprefix = "XANH_SYNC_HOST_ERROR_")]
    public errordomain SyncHostError {
        UNAVAILABLE,
        CORE,
        SECRET_SERVICE,
        INVALID_REDIRECT,
        BUSY,
        BACKED_OFF,
        HISTORY_CLEARED;
        [CCode (cname = "xanh_sync_host_error_quark")]
        public static GLib.Quark quark ();
    }

    [CCode (cname = "XanhSyncReason", cprefix = "XANH_SYNC_REASON_")]
    public enum SyncReason {
        STARTUP,
        MANUAL,
        SCHEDULED,
        LOCAL_CHANGE,
        PRE_SLEEP
    }

    [CCode (cname = "XanhSyncHost", type_id = "xanh_sync_host_get_type ()")]
    public class SyncHost : GLib.Object {
        [CCode (cname = "xanh_sync_host_new")]
        public SyncHost (string profile_dir);
        [CCode (cname = "xanh_sync_write_durable_marker")]
        public static bool write_durable_marker (string path) throws GLib.Error;
        [CCode (cname = "xanh_sync_remove_durable_marker")]
        public static bool remove_durable_marker (string path) throws GLib.Error;
        public bool is_configured ();
        public bool is_ready ();
        public int account_state ();
        public string? dup_account_domain ();
        public string? dup_status ();
        public bool is_redirect_uri (string uri);
        public async bool initialize_async (GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string begin_oauth_async (GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async bool complete_redirect_async (
            string redirect_uri,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public bool sync_due (SyncReason reason, int64 now_epoch_seconds = 0);
        public void mark_local_change (int64 now_epoch_seconds = 0);
        public async string sync_async (
            SyncReason reason,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string import_legacy_bookmarks_async (
            string bookmarks_json,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string bookmarks_json_async (
            int root,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async bool update_bookmark_async (
            string update_json,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async bool delete_bookmark_async (
            string guid,
            bool is_private,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string record_history_async (
            string visits_json,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string recent_history_json_async (
            uint limit,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async bool delete_history_visit_async (
            string url,
            int64 visited_at_epoch_millis,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async bool clear_history_async (
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string update_local_tabs_async (
            string tabs_json,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string remote_tabs_json_async (
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async string credentials_json_async (
            string context_json,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async bool touch_credential_async (
            string credential_id,
            string context_json,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
        public async bool unlock_vault_async (GLib.Cancellable? cancellable = null) throws GLib.Error;
        public bool lock_vault () throws GLib.Error;
        public bool vault_unlocked ();
        public void touch_vault ();
        public async bool disconnect_async (
            bool delete_local,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
    }
}
