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
    test -f desktop/credential-bridge.c
    test -f desktop/credential-bridge.vapi
    test -f desktop/credential-data.vala
    grep -F 'webkit_user_script_new_for_world' desktop/credential-bridge.c >/dev/null
    grep -F 'WEBKIT_USER_CONTENT_INJECT_TOP_FRAME' desktop/credential-bridge.c >/dev/null
    grep -F 'webkit_web_view_call_async_javascript_function' desktop/credential-bridge.c >/dev/null
    grep -F "if (!event.isTrusted) return;" desktop/credential-bridge.c >/dev/null
    grep -F 'CredentialBridge? credential_bridge = null;' desktop/browser-window.vala >/dev/null
    grep -F 'credential_bridge = new CredentialBridge (manager, view);' desktop/browser-window.vala >/dev/null
    grep -F 'if (!private_mode) {' desktop/browser-window.vala >/dev/null
    grep -F 'x-scheme-handler/xanh-browser' data-xanh/io.github.lamppkk.xanhbrowser.desktop >/dev/null
    test -f platform/apple/Sources/XanhBrowserCore/FirefoxSyncCoordinator.swift
    test -f platform/apple/App/BrowserCredentialBridge.swift
    grep -F 'forMainFrameOnly: true' \
      platform/apple/App/BrowserCredentialBridge.swift >/dev/null
    grep -F 'if (!event.isTrusted) return;' \
      platform/apple/App/BrowserCredentialBridge.swift >/dev/null
    grep -F 'let bridge = isPrivate ? nil : BrowserCredentialBridge()' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'xanh-browser-macos' platform/apple/project.yml >/dev/null
    grep -F 'xanh-browser-ios' platform/apple/project.yml >/dev/null
    test -f platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs
    grep -F 'xanh-browser-windows://accounts/oauth' \
      platform/windows/src/XanhBrowser.Windows/WindowsFirefoxSyncConfiguration.cs >/dev/null
    test -f app-webkit/wpe-fork/WPE_ANDROID_REVISION
    test -f app-webkit/wpe-fork/CERBERO_REVISION
    test -f app-webkit/wpe-fork/WPE_RUNTIME_VERSION
    test -f app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch
    test -x scripts/verify-wpe-android-fork.sh
    test -x scripts/verify-android-16k.sh
    test "$(cat app-webkit/wpe-fork/WPE_RUNTIME_VERSION)" = "$(cat WEBKITGTK_MIN_VERSION)"
    grep -F 'WEBKIT_USER_CONTENT_INJECT_TOP_FRAME' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'register_script_message_handler_in_world' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'webkit_web_view_call_async_javascript_function' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'webkit_navigation_action_is_user_gesture' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'webkit_navigation_action_is_redirect' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'shouldOverrideUrlLoading' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F -- '-Wl,-z,max-page-size=16384' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'WPE Android, WPEView and WPE WebKit' THIRD_PARTY_NOTICES.md >/dev/null
    test -f sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt
    grep -F 'window.top !== window' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'event.isTrusted' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'globalThis.crypto.getRandomValues' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'BridgePolicy.validate' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'callIsolatedJavascriptFunction' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'navigationChallenge' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'expectedRequestId !== requestedForId' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'result == "true"' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'fun foregrounded()' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'bootstrapAndBind' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'fun bootstrapFunctionBody(): String = "return' \
      sync-feature-common/src/main/java/io/github/lamppkk/xanhbrowser/lite/sync/WpeCredentialBridge.kt >/dev/null
    grep -F 'BuildConfig.XANH_WPE_SOURCE_FORK' \
      app-webkit/src/main/java/io/github/lamppkk/xanhbrowser/lite/webkit/SyncFeatureInstaller.kt >/dev/null
    test -f app-webkit/src/androidTest/java/io/github/lamppkk/xanhbrowser/lite/webkit/WpeForkApiContractTest.kt
    test -f app-webkit/src/main/java/io/github/lamppkk/xanhbrowser/lite/webkit/XanhWPEViewClient.java
    test -f app-webkit/src/main/java/io/github/lamppkk/xanhbrowser/lite/webkit/WebKitNavigationPolicy.kt
    test -f platform/windows-webkit/WEBKIT_RELEASE_TAG
    test -f platform/windows-webkit/WEBKIT_REVISION
    test "$(cat platform/windows-webkit/WEBKIT_RELEASE_TAG)" = \
      "webkitgtk-$(cat WEBKITGTK_MIN_VERSION)"
    wincairo_revision="$(cat platform/windows-webkit/WEBKIT_REVISION)"
    if [[ ! "$wincairo_revision" =~ ^[0-9a-f]{40}$ ]]; then
      echo 'WinCairo WEBKIT_REVISION must contain exactly one lowercase 40-character Git object ID' >&2
      exit 1
    fi
    ;;
  linux)
    verify_native_core
    test -f desktop/sync-host.c
    test -f desktop/sync-host.vapi
    test -f desktop/credential-bridge.c
    grep -F 'webkit_user_script_new_for_world' desktop/credential-bridge.c >/dev/null
    grep -F 'webkit_web_view_call_async_javascript_function' desktop/credential-bridge.c >/dev/null
    grep -F 'if (!event.isTrusted) return;' desktop/credential-bridge.c >/dev/null
    grep -F 'credential_bridge = new CredentialBridge (manager, view);' desktop/browser-window.vala >/dev/null
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
    test -f platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs
    grep -F 'XanhSyncNativeDll' \
      platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj >/dev/null
    grep -F 'xanh-browser-windows://accounts/oauth' \
      platform/windows/src/XanhBrowser.Windows/WindowsFirefoxSyncConfiguration.cs >/dev/null
    grep -F 'settings.IsWebMessageEnabled = _credentialPicker is not null && !_isPrivate;' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
    grep -F "if (!event.isTrusted) return;" \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
    grep -F '_credentialNonce != nonce' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
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
    grep -F 'WKContentWorld.world' platform/apple/App/BrowserCredentialBridge.swift >/dev/null
    grep -F 'forMainFrameOnly: true' platform/apple/App/BrowserCredentialBridge.swift >/dev/null
    grep -F 'if (!event.isTrusted) return;' \
      platform/apple/App/BrowserCredentialBridge.swift >/dev/null
    grep -F 'let bridge = isPrivate ? nil : BrowserCredentialBridge()' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'xanh-browser-macos' platform/apple/project.yml >/dev/null
    grep -F 'xanh-browser-ios' platform/apple/project.yml >/dev/null
    test "${XANH_APPLE_SYNC_BRIDGE_REVIEWED:-0}" = 1
    ;;
  android)
    test -n "${XANH_FXA_CLIENT_ID:-}" || test "${XANH_SYNC_SELF_HOSTED_ONLY:-0}" = 1
    test "${XANH_ANDROID_SYNC_BRIDGE_REVIEWED:-0}" = 1
    ;;
  wpe)
    grep -F 'BuildConfig.XANH_WPE_SOURCE_FORK' \
      app-webkit/src/main/java/io/github/lamppkk/xanhbrowser/lite/webkit/SyncFeatureInstaller.kt >/dev/null
    grep -F 'WpeCredentialBridge' \
      app-webkit/src/main/java/io/github/lamppkk/xanhbrowser/lite/webkit/SyncFeatureInstaller.kt >/dev/null
    grep -F 'WebKitNavigationPolicy.decide' \
      app-webkit/src/main/java/io/github/lamppkk/xanhbrowser/lite/webkit/WebKitBrowserActivity.kt >/dev/null
    require_evidence XANH_WPE_FORK_BUILD_EVIDENCE
    require_evidence XANH_WPE_16K_EVIDENCE
    require_evidence XANH_WPE_BRIDGE_REVIEW_EVIDENCE
    require_evidence XANH_WPE_DEVICE_TEST_EVIDENCE
    require_evidence XANH_WPE_SBOM_EVIDENCE
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
