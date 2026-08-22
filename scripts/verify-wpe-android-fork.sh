#!/usr/bin/env bash
set -euo pipefail

checkout="${1:-}"
cerbero_checkout="${2:-}"
if [[ -z "$checkout" || ! -d "$checkout/.git" && ! -f "$checkout/.git" ]]; then
  echo "Usage: $0 /path/to/clean/wpe-android-checkout [/path/to/clean/cerbero-checkout]" >&2
  exit 2
fi
if [[ -n "$cerbero_checkout" && ! -d "$cerbero_checkout/.git" && ! -f "$cerbero_checkout/.git" ]]; then
  echo "Cerbero checkout is not a Git worktree: $cerbero_checkout" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fork="$root/app-webkit/wpe-fork"
patch="$fork/patches/xanh-isolated-bridge.patch"

read_pin() {
  path="$1"
  pattern="$2"
  label="$3"
  line_count="$(wc -l < "$path" | tr -d '[:space:]')"
  value="$(<"$path")"
  if [[ "$line_count" != 1 || ! "$value" =~ $pattern ]]; then
    echo "$label must contain exactly one valid line" >&2
    exit 1
  fi
  printf '%s' "$value"
}

expected_revision="$(read_pin "$fork/WPE_ANDROID_REVISION" '^[0-9a-f]{40}$' 'WPE_ANDROID_REVISION')"
expected_cerbero="$(read_pin "$fork/CERBERO_REVISION" '^[0-9a-f]{40}$' 'CERBERO_REVISION')"
expected_runtime="$(read_pin "$fork/WPE_RUNTIME_VERSION" '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' 'WPE_RUNTIME_VERSION')"
project_baseline="$(read_pin "$root/WEBKITGTK_MIN_VERSION" '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' 'WEBKITGTK_MIN_VERSION')"
actual_revision="$(git -C "$checkout" rev-parse HEAD)"
cerbero_patch="$fork/patches/cerbero-wpewebkit-$expected_runtime.patch"

test "$actual_revision" = "$expected_revision"
test "$expected_runtime" = "$project_baseline"
git -C "$checkout" diff --quiet
git -C "$checkout" diff --cached --quiet
if [[ -n "$(git -C "$checkout" status --porcelain --untracked-files=normal)" ]]; then
  echo "WPE Android checkout must not contain untracked files" >&2
  exit 1
fi
git -C "$checkout" apply --check "$patch"

if [[ -n "$cerbero_checkout" ]]; then
  actual_cerbero="$(git -C "$cerbero_checkout" rev-parse HEAD)"
  test "$actual_cerbero" = "$expected_cerbero"
  git -C "$cerbero_checkout" diff --quiet
  git -C "$cerbero_checkout" diff --cached --quiet
  if [[ -n "$(git -C "$cerbero_checkout" status --porcelain --untracked-files=normal)" ]]; then
    echo "Cerbero checkout must not contain untracked files" >&2
    exit 1
  fi
  git -C "$cerbero_checkout" apply --check "$cerbero_patch"
fi

grep -F "_cerbero_revision = \"$expected_cerbero\"" "$patch" >/dev/null
grep -F "_pinned_wpewebkit_version = \"$expected_runtime\"" "$patch" >/dev/null
grep -F '["bootstrap", "--system=no"]' "$patch" >/dev/null
grep -F 'providers.gradleProperty("wpeInstallDeveloperHooks").orNull == "true"' \
  "$patch" >/dev/null
grep -F '_wpewebkit_checksum = "b2bafef2751625b7fdf530f230ff0f542ff0eeba3590c3a989d931b2a55c858e"' "$patch" >/dev/null
grep -F 'distributionSha256Sum=7a00d51fb93147819aab76024feece20b6b84e420694101f276be952e08bef03' "$patch" >/dev/null
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
