/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class PopupPolicy : Object {
        public const uint MAX_TABS = 100;
        public const int64 COOLDOWN_MICROSECONDS = 1000000;
        public const uint READY_TIMEOUT_SECONDS = 15;

        public static bool can_create (
                string? source_uri,
                string? target_uri,
                bool user_gesture,
                bool redirect,
                bool link_clicked,
                uint mouse_button,
                bool window_active,
                bool source_selected,
                bool source_process_stopped,
                bool clearing_data,
                uint tab_count,
                int64 last_accepted_monotonic_us,
                int64 now_monotonic_us) {
            if (!AddressResolver.is_safe_web_uri (source_uri) ||
                    !AddressResolver.is_safe_navigation_uri (target_uri) ||
                    !user_gesture || redirect || !link_clicked ||
                    (mouse_button != 1 && mouse_button != 2) ||
                    !window_active || !source_selected || source_process_stopped ||
                    clearing_data || tab_count >= MAX_TABS || now_monotonic_us <= 0) {
                return false;
            }
            return last_accepted_monotonic_us <= 0 ||
                (now_monotonic_us > last_accepted_monotonic_us &&
                    now_monotonic_us - last_accepted_monotonic_us >=
                        COOLDOWN_MICROSECONDS);
        }
    }
}
