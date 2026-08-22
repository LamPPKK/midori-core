/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class WebProcessRecoveryPolicy : Object {
        string? committed_uri;
        bool automatic_recovery_committed;

        public bool automatic_recovery_used { get; private set; }
        public bool automatic_recovery_running { get; private set; }
        public bool process_stopped { get; private set; }
        public string? recovery_uri { get; private set; }

        public void reset_for_explicit_navigation () {
            committed_uri = null;
            recovery_uri = null;
            automatic_recovery_used = false;
            automatic_recovery_running = false;
            automatic_recovery_committed = false;
            process_stopped = false;
        }

        public void record_committed_uri (string? uri) {
            committed_uri = AddressResolver.is_safe_web_uri (uri) ? uri : null;
            if (automatic_recovery_running) {
                automatic_recovery_committed = true;
                recovery_uri = committed_uri;
            }
        }

        public void record_termination () {
            automatic_recovery_running = false;
            automatic_recovery_committed = false;
            process_stopped = true;
            recovery_uri = committed_uri;
        }

        public string? take_automatic_recovery (bool foreground) {
            if (!foreground || automatic_recovery_used || recovery_uri == null)
                return null;
            automatic_recovery_used = true;
            automatic_recovery_running = true;
            automatic_recovery_committed = false;
            return recovery_uri;
        }

        public bool finish_automatic_recovery (bool success) {
            if (!automatic_recovery_running) return false;
            if (success && !automatic_recovery_committed) return false;
            automatic_recovery_running = false;
            automatic_recovery_committed = false;
            if (success) {
                process_stopped = false;
                recovery_uri = null;
            }
            return true;
        }

        public bool cancel_automatic_recovery () {
            if (!automatic_recovery_running) return false;
            automatic_recovery_running = false;
            automatic_recovery_committed = false;
            return true;
        }
    }
}
