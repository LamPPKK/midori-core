#!/usr/bin/env bash
set -euo pipefail

edition="${1:-source}"
lock='xanh-sync-core/APPLICATION_SERVICES.lock'

grep -Fx 'version=155.0' "$lock" >/dev/null
grep -Fx 'revision=c0fd8cea40c9b5dafc6604831f7bd7a8c096d313' "$lock" >/dev/null
grep -F 'Application Services 155.0' THIRD_PARTY_NOTICES.md >/dev/null
grep -F 'MPL-2.0' THIRD_PARTY_NOTICES.md >/dev/null
if grep -R -E 'application-services.+(nightly|main|master)' xanh-sync-core/Cargo.toml xanh-sync-core/APPLICATION_SERVICES.lock; then
  echo 'Nightly or floating Application Services dependency is forbidden' >&2
  exit 1
fi

verify_native_core() {
  test -n "${XANH_SYNC_NATIVE_CORE:-}"
  test -f "$XANH_SYNC_NATIVE_CORE"
  test -n "${XANH_SYNC_NATIVE_SHA256:-}"
  actual="$(shasum -a 256 "$XANH_SYNC_NATIVE_CORE" | awk '{print $1}')"
  test "$actual" = "$XANH_SYNC_NATIVE_SHA256"
}

require_evidence() {
  name="$1"
  value="${!name:-}"
  if [[ -z "$value" || ! -f "$value" ]]; then
    echo "Missing release evidence file: $name" >&2
    exit 1
  fi
}

case "$edition" in
  source)
    test -f xanh-sync-core/Cargo.lock
    test -f xanh-sync-core/include/xanh_sync.h
    grep -F 'xanh_sync_runtime_update_local_tabs' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_remote_tabs_json' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_bookmark_root_guid' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_create_bookmark' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_import_legacy_bookmarks' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_bookmarks_json' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_update_bookmark' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_delete_bookmark' xanh-sync-core/include/xanh_sync.h >/dev/null
    if grep -F 'bookmarks_get_tree' xanh-sync-core/src/mozilla.rs >/dev/null; then
        echo "Production Places bridge must not materialize an unbounded deepest bookmark tree" >&2
        exit 1
    fi
    grep -F 'xanh_sync_runtime_record_history' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_recent_history_json' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_delete_history_visit' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_clear_history' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_credentials_json' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_add_credential' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_update_credential' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_delete_credential' xanh-sync-core/include/xanh_sync.h >/dev/null
    grep -F 'xanh_sync_runtime_touch_credential' xanh-sync-core/include/xanh_sync.h >/dev/null
    test -f desktop/sync-host.c
    test -f desktop/sync-host.vapi
    test -f desktop/sync-data.vala
    grep -F 'x-scheme-handler/xanh-browser' data-xanh/io.github.lamppkk.xanhbrowser.desktop >/dev/null
    test -f platform/apple/Sources/XanhBrowserCore/FirefoxSyncCoordinator.swift
    grep -F 'xanh-browser-macos' platform/apple/project.yml >/dev/null
    grep -F 'xanh-browser-ios' platform/apple/project.yml >/dev/null
    test -f platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs
    grep -F 'xanh-browser-windows://accounts/oauth' \
      platform/windows/src/XanhBrowser.Windows/WindowsFirefoxSyncConfiguration.cs >/dev/null
    ;;
  linux)
    verify_native_core
    test -f desktop/sync-host.c
    test -f desktop/sync-host.vapi
    grep -F 'XANH_ENABLE_FIREFOX_SYNC' CMakeLists.txt >/dev/null
    grep -F 'x-scheme-handler/xanh-browser' data-xanh/io.github.lamppkk.xanhbrowser.desktop >/dev/null
    require_evidence XANH_LINUX_SYNC_BUILD_EVIDENCE
    require_evidence XANH_LINUX_SECRET_SERVICE_EVIDENCE
    require_evidence XANH_LINUX_INTEROP_EVIDENCE
    require_evidence XANH_LINUX_DATA_MIGRATION_EVIDENCE
    require_evidence XANH_LINUX_FLATPAK_EVIDENCE
    require_evidence XANH_LINUX_USER_PRESENCE_EVIDENCE
    require_evidence XANH_LINUX_SECURITY_REVIEW_EVIDENCE
    ;;
  windows)
    verify_native_core
    test -f platform/windows/src/XanhBrowser.Windows/WindowsSyncSecretStore.cs
    test -f platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs
    grep -F 'XanhSyncNativeDll' \
      platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj >/dev/null
    grep -F 'xanh-browser-windows://accounts/oauth' \
      platform/windows/src/XanhBrowser.Windows/WindowsFirefoxSyncConfiguration.cs >/dev/null
    test "${XANH_WINDOWS_HELLO_TESTED:-0}" = 1
    test "${XANH_WEBVIEW2_SYNC_BRIDGE_REVIEWED:-0}" = 1
    ;;
  apple)
    test -d platform/apple/MozillaRustComponents.xcframework
    test -f platform/apple/MozillaRustComponents.checksum
    (cd platform/apple && shasum -a 256 -c MozillaRustComponents.checksum)
    test -f platform/apple/Generated/xanh_sync_core.swift
    grep -F 'class MozillaSyncRuntime' platform/apple/Generated/xanh_sync_core.swift >/dev/null
    grep -F 'XANH_SYNC_SWIFT_FLAGS' platform/apple/project.yml >/dev/null
    grep -F 'xanh-browser-macos' platform/apple/project.yml >/dev/null
    grep -F 'xanh-browser-ios' platform/apple/project.yml >/dev/null
    test "${XANH_APPLE_SYNC_BRIDGE_REVIEWED:-0}" = 1
    ;;
  android)
    test -n "${XANH_FXA_CLIENT_ID:-}" || test "${XANH_SYNC_SELF_HOSTED_ONLY:-0}" = 1
    test "${XANH_ANDROID_SYNC_BRIDGE_REVIEWED:-0}" = 1
    ;;
  wpe)
    test "${XANH_WPE_ISOLATED_BRIDGE:-0}" = 1
    test "${XANH_ANDROID_16K_NATIVE_OK:-0}" = 1
    ;;
  wincairo)
    test "${XANH_WINCAIRO_ISOLATED_BRIDGE:-0}" = 1
    test "${XANH_WINCAIRO_VAULT_OK:-0}" = 1
    ;;
  *)
    echo "Unknown Sync edition: $edition" >&2
    exit 2
    ;;
esac

if [[ "${XANH_SYNC_MOZILLA_HOSTED:-0}" == 1 ]]; then
  test -n "${XANH_FXA_CLIENT_ID:-}"
  test "${XANH_FXA_PRODUCTION_APPROVED:-0}" = 1
fi

echo "Firefox Sync release prerequisites verified for $edition"
