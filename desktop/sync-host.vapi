/* SPDX-License-Identifier: LGPL-2.1-or-later */
[CCode (cheader_filename = "sync-host.h")]
namespace Xanh {
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
        public async bool unlock_vault_async (GLib.Cancellable? cancellable = null) throws GLib.Error;
        public bool lock_vault () throws GLib.Error;
        public bool vault_unlocked ();
        public void touch_vault ();
        public async bool disconnect_async (
            bool delete_local,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
    }
}
