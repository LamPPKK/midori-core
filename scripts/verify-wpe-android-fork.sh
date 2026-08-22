#!/usr/bin/env bash
set -euo pipefail

checkout="${1:-}"
if [[ -z "$checkout" || ! -d "$checkout/.git" && ! -f "$checkout/.git" ]]; then
  echo "Usage: $0 /path/to/clean/wpe-android-checkout" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fork="$root/app-webkit/wpe-fork"
patch="$fork/patches/xanh-isolated-bridge.patch"
expected_revision="$(tr -d '\r\n' < "$fork/WPE_ANDROID_REVISION")"
expected_cerbero="$(tr -d '\r\n' < "$fork/CERBERO_REVISION")"
expected_runtime="$(tr -d '\r\n' < "$fork/WPE_RUNTIME_VERSION")"
project_baseline="$(tr -d '\r\n' < "$root/WEBKITGTK_MIN_VERSION")"
actual_revision="$(git -C "$checkout" rev-parse HEAD)"

test "$actual_revision" = "$expected_revision"
test "$expected_runtime" = "$project_baseline"
git -C "$checkout" diff --quiet
git -C "$checkout" diff --cached --quiet
git -C "$checkout" apply --check "$patch"

grep -F "_cerbero_revision = \"$expected_cerbero\"" "$patch" >/dev/null
grep -F "_pinned_wpewebkit_version = \"$expected_runtime\"" "$patch" >/dev/null
grep -F '_wpewebkit_checksum = "b2bafef2751625b7fdf530f230ff0f542ff0eeba3590c3a989d931b2a55c858e"' "$patch" >/dev/null
grep -F 'WEBKIT_USER_CONTENT_INJECT_TOP_FRAME' "$patch" >/dev/null
grep -F 'register_script_message_handler_in_world' "$patch" >/dev/null
grep -F 'webkit_web_view_call_async_javascript_function' "$patch" >/dev/null
grep -F 'WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION' "$patch" >/dev/null
grep -F 'webkit_navigation_action_is_user_gesture' "$patch" >/dev/null
grep -F 'webkit_navigation_action_is_redirect' "$patch" >/dev/null
grep -F 'shouldOverrideUrlLoading' "$patch" >/dev/null
grep -F -- '-Wl,-z,max-page-size=16384' "$patch" >/dev/null
grep -F -- '-Wl,-z,common-page-size=16384' "$patch" >/dev/null

echo "WPE Android fork contract verified at $actual_revision"
