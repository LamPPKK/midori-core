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
  if [[ -z "$value" || ! -f "$value" || -L "$value" ]]; then
    echo "Missing release evidence file: $name" >&2
    exit 1
  fi
}

verify_apple_remote_tabs() {
  coordinator='platform/apple/Sources/XanhBrowserCore/FirefoxSyncCoordinator.swift'
  runtime='platform/apple/App/AppleFirefoxSyncRuntime.swift'
  settings='platform/apple/App/FirefoxSyncSettingsView.swift'
  workspace='platform/apple/App/BrowserModel.swift'
  browser='platform/apple/App/BrowserView.swift'

  grep -F 'public struct XanhRemoteTab:' "$coordinator" >/dev/null
  grep -F 'public static let maximumDevices = 100' "$coordinator" >/dev/null
  grep -F 'public static let maximumTotalTabs = 500' "$coordinator" >/dev/null
  grep -F 'public static let maximumPayloadBytes = 8 * 1_024 * 1_024' \
    "$coordinator" >/dev/null
  grep -F "Set(devices.map { \$0.deviceID }).count == devices.count" \
    "$coordinator" >/dev/null
  grep -F 'try device.tabs.enumerated().map' "$runtime" >/dev/null
  grep -F 'ForEach(model.remoteTabs)' "$settings" >/dev/null
  grep -F 'onOpenRemoteTab(url)' "$settings" >/dev/null
  grep -F 'guard initialURL.map(AddressResolver.isAllowedWebURL) ?? true' \
    "$workspace" >/dev/null
  grep -F '_ = workspace.addTab(initialURL: url)' "$browser" >/dev/null
  if grep -R -F 'remoteTabsSummary' platform/apple >/dev/null; then
    echo 'Apple Remote Tabs must expose explicit typed rows, not a count-only summary' >&2
    exit 1
  fi
}

case "$edition" in
  source)
    test -x scripts/verify_webkit_latest.py
    test -f scripts/tests/test_verify_webkit_latest.py
    test -x scripts/verify_androidx_webkit_latest.py
    test -f scripts/tests/test_verify_androidx_webkit_latest.py
    test -x scripts/verify_webview2_latest.py
    test -f scripts/tests/test_verify_webview2_latest.py
    test -f .github/workflows/webkit-baseline.yml
    test -f .github/workflows/webview2-baseline.yml
    grep -F 'python3 scripts/verify_androidx_webkit_latest.py' .github/workflows/webkit-baseline.yml >/dev/null
    grep -F 'python3 scripts/verify_webview2_latest.py' .github/workflows/webview2-baseline.yml >/dev/null
    grep -F 'def verify_popup_contract(' scripts/verify_webkit_latest.py >/dev/null
    grep -F 'mouseEventData->buttonDown && mouseEventData->isTrusted' \
      scripts/verify_webkit_latest.py >/dev/null
    test "$(grep -Fc 'desktop/popup-policy.vala' \
      .github/workflows/webkit-baseline.yml)" -eq 2
    test "$(grep -Fc 'desktop/web-extension-bridge.vala' \
      .github/workflows/webkit-baseline.yml)" -eq 2
    grep -F 'TargetCompatibleBrowserVersion = WebView2RuntimePolicy.MinimumVersion' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
    grep -F 'ReleaseChannels = CoreWebView2ReleaseChannels.Stable' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
    grep -F 'WebView2RuntimePolicy.IsSupported(environment.BrowserVersionString)' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
    grep -F 'WebView2ProcessRecoveryPolicy.SelectAutomaticTarget' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
    grep -F 'automaticRecoveryUsed: true' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    test -f platform/windows/tests/XanhBrowser.Core.Tests/WebView2ProcessRecoveryPolicyTests.cs
    if sed -n \
      '/private void CoreWebView2_ProcessFailed(/,/private void RequestAutomaticRecovery()/p' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs \
        | grep -F 'BrowserWebView.Reload()' >/dev/null; then
      echo 'WebView2 process failure must never call Reload automatically' >&2
      exit 1
    fi
    python3 -B -m unittest discover -s scripts/tests -p 'test_verify_webkit_latest.py' >/dev/null
    python3 -B -m unittest discover -s scripts/tests -p 'test_verify_androidx_webkit_latest.py' >/dev/null
    python3 -B -m unittest discover -s scripts/tests -p 'test_verify_webview2_latest.py' >/dev/null
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
    test -f desktop/web-process-recovery.vala
    test -f tests-modern/web-process-recovery-test.vala
    grep -F 'MAX_WEB_URI_BYTES = 8192' desktop/page-data-policy.vala >/dev/null
    grep -F 'parsed.get_userinfo () == null' desktop/page-data-policy.vala >/dev/null
    grep -F 'value.contains ("\\")' desktop/page-data-policy.vala >/dev/null
    grep -F 'decoded.contains ("\\")' desktop/page-data-policy.vala >/dev/null
    grep -F 'return PageDataPolicy.is_safe_web_uri (input);' \
      desktop/address-resolver.vala >/dev/null
    grep -F 'return PageDataPolicy.is_safe_navigation_uri (input);' \
      desktop/address-resolver.vala >/dev/null
    grep -F 'return PageDataPolicy.is_safe_web_uri (uri);' \
      desktop/database.vala >/dev/null
    grep -F 'return PageDataPolicy.is_safe_web_uri (uri);' \
      desktop/sync-data.vala >/dev/null
    grep -F 'take_automatic_recovery (true)' desktop/browser-window.vala >/dev/null
    sed -n '/void maybe_recover_tab/,/void show_process_stopped/p' \
      desktop/browser-window.vala | grep -F 'tab.view.load_uri (uri);' >/dev/null
    if sed -n '/tab.view.web_process_terminated.connect/,/^            });/p' \
      desktop/browser-window.vala | \
      grep -E 'load_alternate_html|\.reload \(|go_back|go_forward' >/dev/null; then
      echo 'Linux WebProcess termination must not reload or restore navigation automatically' >&2
      exit 1
    fi
    if sed -n '/void maybe_recover_tab/,/void show_process_stopped/p' \
      desktop/browser-window.vala | \
      grep -E 'load_alternate_html|\.reload \(|go_back|go_forward' >/dev/null; then
      echo 'Linux automatic recovery must use a fresh URI load only' >&2
      exit 1
    fi
    test -f desktop/external-navigation-bridge.c
    test -f desktop/external-navigation-data.c
    test -f tests-modern/external-navigation-bridge-test.c
    grep -F 'MAX_EXTERNAL_URI_BYTES = 2048' desktop/address-resolver.vala >/dev/null
    grep -F 'webkit_user_script_new_for_world' \
      desktop/external-navigation-bridge.c >/dev/null
    grep -F 'WEBKIT_USER_CONTENT_INJECT_TOP_FRAME' \
      desktop/external-navigation-bridge.c >/dev/null
    grep -F 'WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START' \
      desktop/external-navigation-bridge.c >/dev/null
    grep -F "if (!event.isTrusted" desktop/external-navigation-bridge.c >/dev/null
    grep -F 'event.stopImmediatePropagation();' \
      desktop/external-navigation-bridge.c >/dev/null
    grep -F 'tab.view.decide_policy.connect' desktop/browser-window.vala >/dev/null
    grep -F 'decision.use ();' desktop/browser-window.vala >/dev/null
    grep -F 'decision.ignore ();' desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.uri != document_uri' desktop/browser-window.vala >/dev/null
    grep -F 'AddressResolver.is_safe_external_uri' desktop/browser-window.vala >/dev/null
    grep -F 'disconnect_tab_bridges (tab);' desktop/browser-window.vala >/dev/null
    grep -F 'add_executable(external-navigation-bridge-test' CMakeLists.txt >/dev/null
    test -f desktop/popup-policy.vala
    test -f tests-modern/popup-policy-test.vala
    grep -F 'add_xanh_test(popup-policy-test' CMakeLists.txt >/dev/null
    grep -F 'MAX_TABS = 100' desktop/popup-policy.vala >/dev/null
    grep -F 'COOLDOWN_MICROSECONDS = 1000000' desktop/popup-policy.vala >/dev/null
    grep -F 'READY_TIMEOUT_SECONDS = 15' desktop/popup-policy.vala >/dev/null
    grep -F 'PopupPolicy.can_create (' desktop/browser-window.vala >/dev/null
    grep -F 'navigation.is_user_gesture (), navigation.is_redirect ()' \
      desktop/browser-window.vala >/dev/null
    grep -F 'WebKit.NavigationType.LINK_CLICKED' desktop/browser-window.vala >/dev/null
    grep -F 'navigation.get_mouse_button ()' desktop/browser-window.vala >/dev/null
    grep -F '"related-view", related_view' desktop/browser-window.vala >/dev/null
    grep -F 'popup.view.ready_to_show.connect' desktop/browser-window.vala >/dev/null
    grep -F 'active_tab () == opener && is_active' desktop/browser-window.vala >/dev/null
    grep -F 'opener.view.uri == popup.popup_opener_uri' \
      desktop/browser-window.vala >/dev/null
    grep -F 'cancel_pending_popups (tab);' desktop/browser-window.vala >/dev/null
    grep -F 'cancel_pending_popups ();' desktop/browser-window.vala >/dev/null
    grep -F 'popup_adblock_ready ()' desktop/browser-window.vala >/dev/null
    grep -F 'if (!record.pending_popup)' desktop/browser-window.vala >/dev/null
    grep -F 'bridge.set_message_dispatch_enabled (!pending_popup);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'popup.bridge.set_message_dispatch_enabled (true);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'if (!message_dispatch_enabled && !default_world)' \
      desktop/web-extension-bridge.vala >/dev/null
    grep -F 'tab.pending_popup_load_finished = true;' \
      desktop/browser-window.vala >/dev/null
    grep -F 'if (exposed_page) publish_page_loaded (tab);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'source_tab.pending_popup' desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.run_file_chooser.connect' desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.permission_request.connect' desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.authenticate.connect' desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.run_color_chooser.connect' desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.script_dialog.connect' desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.show_notification.connect' desktop/browser-window.vala >/dev/null
    grep -F 'load_tab_with_adblock.begin' desktop/browser-window.vala >/dev/null
    grep -F 'expected_generation != adblock_generation' \
      desktop/browser-window.vala >/dev/null
    if sed -n '/tab.view.create.connect/,/^            });/p' \
      desktop/browser-window.vala | grep -F 'add_tab (' >/dev/null; then
      echo 'Linux popup creation must return a related view, not an ordinary tab' >&2
      exit 1
    fi
    test -f desktop/file-upload-policy.vala
    test -f tests-modern/file-upload-policy-test.vala
    grep -F 'add_xanh_test(file-upload-policy-test' CMakeLists.txt >/dev/null
    grep -F 'MAX_SELECTED_FILES = 32' desktop/file-upload-policy.vala >/dev/null
    grep -F 'MAX_PATH_BYTES = 4096' desktop/file-upload-policy.vala >/dev/null
    grep -F 'MAX_TOTAL_PATH_BYTES = 64 * 1024' \
      desktop/file-upload-policy.vala >/dev/null
    grep -F 'contains_percent_escape (path)' \
      desktop/file-upload-policy.vala >/dev/null
    grep -F 'TIMEOUT_SECONDS = 5 * 60' desktop/file-upload-policy.vala >/dev/null
    grep -F 'AddressResolver.is_safe_secure_web_uri' \
      desktop/file-upload-policy.vala >/dev/null
    grep -F 'FileUploadPolicy.can_begin (' desktop/browser-window.vala >/dev/null
    grep -F 'FileUploadPolicy.can_complete (' desktop/browser-window.vala >/dev/null
    grep -F 'request.get_mime_types_filter ()' desktop/browser-window.vala >/dev/null
    grep -F 'Gtk.FileFilter? filter = request.get_mime_types_filter ();' \
      desktop/browser-window.vala >/dev/null
    grep -F 'if (filter != null)' desktop/browser-window.vala >/dev/null
    grep -F 'dialog.open_multiple (this, cancellable)' \
      desktop/browser-window.vala >/dev/null
    grep -F 'dialog.open (this, cancellable)' desktop/browser-window.vala >/dev/null
    grep -F 'request.select_files (selected_paths);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'finish_file_upload (true);' desktop/browser-window.vala >/dev/null
    grep -F 'cancel_file_upload (tab);' desktop/browser-window.vala >/dev/null
    if sed -n '/tab.view.run_file_chooser.connect/,/^            });/p' \
      desktop/browser-window.vala | grep -F 'return false' >/dev/null; then
      echo 'Linux file uploads must not fall through to an uncoordinated default chooser' >&2
      exit 1
    fi
    test -f desktop/page-data-policy.vala
    test -f tests-modern/page-data-policy-test.vala
    grep -F 'desktop/page-data-policy.vala' CMakeLists.txt >/dev/null
    grep -F 'add_xanh_test(page-data-policy-test' CMakeLists.txt >/dev/null
    grep -F 'MAX_TITLE_BYTES = 4096' desktop/page-data-policy.vala >/dev/null
    grep -F 'character.isspace ()' desktop/page-data-policy.vala >/dev/null
    grep -F 'character.type () == UnicodeType.FORMAT' \
      desktop/page-data-policy.vala >/dev/null
    grep -F 'PageDataPolicy.sanitized_title (' desktop/browser-window.vala >/dev/null
    grep -F 'PageDataPolicy.sanitized_title (title, uri)' \
      desktop/database.vala >/dev/null
    grep -F 'return PageDataPolicy.sanitized_title (value, "Untitled");' \
      desktop/sync-data.vala >/dev/null
    grep -F 'if (!is_web_uri (uri)) continue;' desktop/database.vala >/dev/null
    grep -F 'if (!PageDataPolicy.is_safe_navigation_uri (tab.uri)) continue;' \
      desktop/database.vala >/dev/null
    grep -F 'if (!PageDataPolicy.is_safe_navigation_uri (uri)) continue;' \
      desktop/database.vala >/dev/null
    grep -F 'SELECT id, uri, title, visited_at FROM history WHERE private = 0' \
      desktop/database.vala >/dev/null
    grep -F "sync_guid TEXT NOT NULL DEFAULT ''" desktop/database.vala >/dev/null
    grep -F 'sync_millis INTEGER NOT NULL DEFAULT 0' desktop/database.vala >/dev/null
    grep -F 'sync_is_remote INTEGER NOT NULL DEFAULT 0' desktop/database.vala >/dev/null
    grep -F 'xanh_sync_host_delete_bookmark_async' desktop/sync-host.h >/dev/null
    grep -F 'xanh_sync_host_update_bookmark_async' desktop/sync-host.h >/dev/null
    grep -F 'xanh_sync_host_delete_history_visit_async' desktop/sync-host.h >/dev/null
    grep -F 'public async bool delete_bookmark_async (' desktop/sync-host.vapi >/dev/null
    grep -F 'public async bool update_bookmark_async (' desktop/sync-host.vapi >/dev/null
    grep -F 'public async bool delete_history_visit_async (' desktop/sync-host.vapi >/dev/null
    grep -F 'delete_stored_page (StoredPage page' desktop/application.vala >/dev/null
    grep -F 'bool from_places, bool private_context' desktop/application.vala >/dev/null
    grep -F 'rename_stored_bookmark (StoredPage page' desktop/application.vala >/dev/null
    grep -F 'finalize_places_bookmark_rename' desktop/database.vala >/dev/null
    grep -F 'Rename bookmark' desktop/browser-window.vala >/dev/null
    grep -F '!page.sync_is_remote' desktop/sync-data.vala >/dev/null
    grep -F 'schema-v2-sync-identity-upgrade' tests-modern/database-test.vala >/dev/null
    grep -F 'sync-data/bookmark-title-update' \
      tests-modern/sync-data-policy-test.vala >/dev/null
    if grep -F 'tab.state.title = tab.view.title' desktop/browser-window.vala >/dev/null; then
      echo 'Linux page titles must pass the shared bounded data policy' >&2
      exit 1
    fi
    test -f desktop/permission-policy.vala
    test -f tests-modern/permission-policy-test.vala
    grep -F 'add_xanh_test(permission-policy-test' CMakeLists.txt >/dev/null
    grep -F 'AddressResolver.is_safe_secure_web_uri' \
      desktop/permission-policy.vala >/dev/null
    grep -F 'input.length <= 1024' desktop/address-resolver.vala >/dev/null
    grep -F 'requested_document_uri == current_document_uri' \
      desktop/permission-policy.vala >/dev/null
    grep -F 'PermissionPolicy.display_origin' desktop/browser-window.vala >/dev/null
    grep -F 'PermissionPolicy.storage_access_matches_document' \
      desktop/browser-window.vala >/dev/null
    grep -F 'request is WebKit.PointerLockPermissionRequest' \
      desktop/browser-window.vala >/dev/null
    grep -F 'pending_permission_timeout_source = Timeout.add_seconds (30' \
      desktop/browser-window.vala >/dev/null
    grep -F 'pending_permission_document_uri != document_uri' \
      desktop/browser-window.vala >/dev/null
    grep -F 'finish_permission_request (choice == 1);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'cancel_permission_request (tab);' desktop/browser-window.vala >/dev/null
    grep -F 'cancel_permission_request ();' desktop/browser-window.vala >/dev/null
    test -f desktop/tls-error-policy.vala
    test -f tests-modern/tls-error-policy-test.vala
    grep -F 'add_xanh_test(tls-error-policy-test' CMakeLists.txt >/dev/null
    grep -F 'AddressResolver.is_safe_secure_web_uri' \
      desktop/tls-error-policy.vala >/dev/null
    grep -F 'failing_uri == current_uri' desktop/tls-error-policy.vala >/dev/null
    grep -F 'MAX_CERTIFICATE_NAME_BYTES = 1024' \
      desktop/tls-error-policy.vala >/dev/null
    grep -F 'pending_tls_timeout_source = Timeout.add_seconds (30' \
      desktop/browser-window.vala >/dev/null
    grep -F 'pending_tls_uri != uri' desktop/browser-window.vala >/dev/null
    grep -F 'pending_tls_uri != tab.view.uri' desktop/browser-window.vala >/dev/null
    grep -F 'dialog.buttons = { "Back to Safety" };' \
      desktop/browser-window.vala >/dev/null
    grep -F 'cancel_tls_error (tab);' desktop/browser-window.vala >/dev/null
    grep -F 'cancel_tls_error ();' desktop/browser-window.vala >/dev/null
    if grep -R -F 'allow_tls_certificate_for_host' desktop >/dev/null; then
      echo 'Linux TLS failures must not install certificate exceptions' >&2
      exit 1
    fi
    if grep -R -F 'Continue for This Session' desktop >/dev/null; then
      echo 'Linux TLS failures must not expose a bypass action' >&2
      exit 1
    fi
    test -f desktop/http-auth-policy.vala
    test -f tests-modern/http-auth-policy-test.vala
    grep -F 'add_xanh_test(http-auth-policy-test' CMakeLists.txt >/dev/null
    grep -F 'requested_document_uri != current_document_uri' \
      desktop/http-auth-policy.vala >/dev/null
    grep -F 'document_host != challenge_host' \
      desktop/http-auth-policy.vala >/dev/null
    grep -F 'security_origin_port == document_port' \
      desktop/http-auth-policy.vala >/dev/null
    grep -F 'network_session.set_persistent_credential_storage_enabled (false);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'session.set_persistent_credential_storage_enabled (false);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'tab.view.authenticate.connect' desktop/browser-window.vala >/dev/null
    grep -F 'request.set_can_save_credentials (false);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'WebKit.AuthenticationScheme.HTTP_BASIC' \
      desktop/browser-window.vala >/dev/null
    grep -F 'WebKit.AuthenticationScheme.HTTP_DIGEST' \
      desktop/browser-window.vala >/dev/null
    grep -F 'if (!supported_scheme || request.is_for_proxy () || request.is_retry ())' \
      desktop/browser-window.vala >/dev/null
    grep -F 'WebKit.CredentialPersistence.NONE' \
      desktop/browser-window.vala >/dev/null
    grep -F 'pending_auth_timeout_source = Timeout.add_seconds (30' \
      desktop/browser-window.vala >/dev/null
    grep -F 'pending_auth_document_uri != tab.view.uri' \
      desktop/browser-window.vala >/dev/null
    grep -F 'pending_auth_document_uri != document_uri' \
      desktop/browser-window.vala >/dev/null
    grep -F 'Gtk.InputHints.PRIVATE' desktop/browser-window.vala >/dev/null
    grep -F 'cancel_http_auth (tab);' desktop/browser-window.vala >/dev/null
    grep -F 'cancel_http_auth ();' desktop/browser-window.vala >/dev/null
    if grep -R -F 'set_persistent_credential_storage_enabled (true)' desktop >/dev/null; then
      echo 'Linux must not enable WebKit persistent credential storage' >&2
      exit 1
    fi
    if grep -R -E 'CredentialPersistence\.(FOR_SESSION|PERMANENT)|get_proposed_credential' \
      desktop >/dev/null; then
      echo 'Linux HTTP authentication must not propose or persist credentials' >&2
      exit 1
    fi
    test -f desktop/download-policy.vala
    test -f tests-modern/download-policy-test.vala
    grep -F 'add_xanh_test(download-policy-test' CMakeLists.txt >/dev/null
    grep -F 'MAX_SUGGESTED_NAME_BYTES = 240' desktop/download-policy.vala >/dev/null
    grep -F 'MAX_DESTINATION_BYTES = 4096' desktop/download-policy.vala >/dev/null
    grep -F 'dialog.initial_name = DownloadPolicy.sanitize_suggested_filename (suggested);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'dialog.save.begin (this, cancellable' desktop/browser-window.vala >/dev/null
    grep -F 'DownloadPolicy.local_destination_path (file)' \
      desktop/browser-window.vala >/dev/null
    grep -F 'download.set_allow_overwrite (true);' desktop/browser-window.vala >/dev/null
    grep -F 'download.set_destination (path);' desktop/browser-window.vala >/dev/null
    grep -F 'bool failed = failed_downloads.remove (download);' \
      desktop/browser-window.vala >/dev/null
    grep -F 'DownloadPolicy.should_record_finished (failed)' \
      desktop/browser-window.vala >/dev/null
    grep -F 'cancel_pending_download_choices ();' desktop/browser-window.vala >/dev/null
    if grep -F 'dialog.initial_name = suggested;' desktop/browser-window.vala >/dev/null; then
      echo 'Linux must sanitize untrusted server-provided download names' >&2
      exit 1
    fi
    if grep -E 'NotificationPermissionRequest|MediaKeySystemPermissionRequest|ClipboardPermissionRequest|XRPermissionRequest' \
      desktop/browser-window.vala >/dev/null; then
      echo 'Unsupported Linux permission classes must remain deny-by-default' >&2
      exit 1
    fi
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
    test -f platform/apple/Sources/XanhBrowserCore/ExternalNavigationPolicy.swift
    test -f platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift
    grep -F 'maximumWebURLBytes = 8_192' \
      platform/apple/Sources/XanhBrowserCore/AddressResolver.swift >/dev/null
    grep -F 'url.user == nil' \
      platform/apple/Sources/XanhBrowserCore/AddressResolver.swift >/dev/null
    grep -F '!containsPercentEncodedControl(value)' \
      platform/apple/Sources/XanhBrowserCore/AddressResolver.swift >/dev/null
    grep -F 'ExternalNavigationPolicy.allows(' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'sourceIsMainFrame: action.source.isMainFrame' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'hasTrustedButtonActivation: hasTrustedButtonActivation' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'isContentRuleListRedirect: action.isContentRuleListRedirect' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'case .webContentProcessTerminated:' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'request.httpMethod = "GET"' \
      platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift >/dev/null
    grep -F 'cachePolicy: .reloadIgnoringLocalCacheData' \
      platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift >/dev/null
    grep -F 'request.httpBody = nil' \
      platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift >/dev/null
    grep -F 'page.load(request)' platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'cancelInFlightWebContentRecoveryForBackground()' \
      platform/apple/App/BrowserView.swift >/dev/null
    grep -F 'xanh-browser-macos' platform/apple/project.yml >/dev/null
    grep -F 'xanh-browser-ios' platform/apple/project.yml >/dev/null
    verify_apple_remote_tabs
    test -f platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs
    grep -F 'public async Task UpdateLocalTabsAsync(' \
      platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs >/dev/null
    grep -F 'public async Task<IReadOnlyList<FirefoxRemoteTabsDevice>> RemoteTabsAsync(' \
      platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs >/dev/null
    grep -F 'public async Task<IReadOnlyList<FirefoxBookmarkRecord>> BookmarksAsync(' \
      platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs >/dev/null
    grep -F 'public async Task RecordHistoryAsync(' \
      platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs >/dev/null
    grep -F 'browser.PageVisited += Browser_PageVisited;' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'await _sync.SyncAsync(FirefoxSyncReason.LocalChange);' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'coordinator.DeleteBookmarkAsync(selected.Guid' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'coordinator.DeleteHistoryVisitAsync(uri, selected.VisitedAtEpochMillis)' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'clearGeneration != Interlocked.Read(ref _historyClearGeneration)' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    sed -n '/ShowRemoteTabsLibraryAsync/,/private static string RemoteDeviceKindLabel/p' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs \
      | grep -F 'AddTab(isPrivate: false, initialUri: uri);' >/dev/null
    if grep -F 'RemoteTabsSummary(' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null; then
      echo 'Windows remote tabs must expose explicit typed rows, not a count-only summary' >&2
      exit 1
    fi
    grep -F 'xanh-browser-windows://accounts/oauth' \
      platform/windows/src/XanhBrowser.Windows/WindowsFirefoxSyncConfiguration.cs >/dev/null
    test -f app-webkit/wpe-fork/WPE_ANDROID_REVISION
    test -f app-webkit/wpe-fork/CERBERO_REVISION
    test -f app-webkit/wpe-fork/WPE_RUNTIME_VERSION
    test -f app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch
    test -f app-webkit/wpe-fork/patches/cerbero-wpewebkit-2.52.6.patch
    test -f .github/workflows/wpe-android-source-build.yml
    test -f .github/actionlint.yaml
    test -x scripts/build-wpe-android-fork.sh
    test -x scripts/create_wpe_build_evidence.py
    test -x scripts/verify-wpe-android-fork.sh
    test -x scripts/verify-android-16k.sh
    test -f scripts/tests/test_create_wpe_build_evidence.py
    python3 -B -m unittest discover \
      -s scripts/tests -p 'test_create_wpe_build_evidence.py' >/dev/null
    grep -F './scripts/build-wpe-android-fork.sh' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F ':app-webkit:assembleAndroidTest' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F './scripts/verify-android-16k.sh' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F -- "--verify-directory \"\$wpe_evidence_directory\"" \
      scripts/verify-sync-release.sh >/dev/null
    grep -F 'uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F 'uses: actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F '  attest-source-build:' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F '    needs: build-source-fork' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F 'permissions: {}' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F '    runs-on: ubuntu-24.04' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F '          persist-credentials: false' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F "          name: xanh-wpe-android-source-build-\${{ github.sha }}-\${{ github.run_attempt }}" \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F "          name: xanh-wpe-android-source-build-subjects-\${{ github.sha }}-\${{ github.run_attempt }}" \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F "          name: xanh-wpe-android-source-build-attestation-\${{ github.sha }}-\${{ github.run_attempt }}" \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F "          subject-checksums: \${{ env.XANH_WPE_ATTEST_ROOT }}/claims/subject.checksums.txt" \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    if sed -n '/^  build-source-fork:/,/^  attest-source-build:/p' \
      .github/workflows/wpe-android-source-build.yml | \
      grep -E 'id-token: write|attestations: write|artifact-metadata: write' >/dev/null; then
      echo 'Untrusted WPE source builds must not receive OIDC or attestation permissions' >&2
      exit 1
    fi
    if sed -n '/^  attest-source-build:/,$p' \
      .github/workflows/wpe-android-source-build.yml | \
      grep -E 'actions/checkout|subject-path:' >/dev/null; then
      echo 'The attestation job may consume only the fixed checksum manifest' >&2
      exit 1
    fi
    grep -F 'github-attestation.sigstore.json' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F './scripts/verify-wpe-android-fork.sh _wpe_android _cerbero' \
      .github/workflows/webkit-editions.yml >/dev/null
    grep -F "export XDG_CACHE_HOME=\"\$temporary_root/cache\"" \
      scripts/build-wpe-android-fork.sh >/dev/null
    grep -F "export GRADLE_USER_HOME=\"\$temporary_root/gradle-home\"" \
      scripts/build-wpe-android-fork.sh >/dev/null
    grep -F "mv --no-clobber --no-target-directory \"\$staging\" \"\$output\"" \
      scripts/build-wpe-android-fork.sh >/dev/null
    grep -F "if [[ -e \"\$staging\" ]]" scripts/build-wpe-android-fork.sh >/dev/null
    if grep -F 'sudo ' .github/workflows/wpe-android-source-build.yml >/dev/null; then
      echo 'The ephemeral WPE self-hosted runner must not be mutated with sudo' >&2
      exit 1
    fi
    grep -F 'runs-on: [self-hosted, linux, x64, xanh-wpe-android-ephemeral]' \
      .github/workflows/wpe-android-source-build.yml >/dev/null
    grep -F '    - xanh-wpe-android-ephemeral' .github/actionlint.yaml >/dev/null
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
    grep -F '["bootstrap", "--system=no"]' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'distributionSha256Sum=7a00d51fb93147819aab76024feece20b6b84e420694101f276be952e08bef03' \
      app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch >/dev/null
    grep -F 'WPE Android, WPEView and WPE WebKit' THIRD_PARTY_NOTICES.md >/dev/null
    grep -F 'app-webkit/wpe-fork/patches/cerbero-wpewebkit-2.52.6.patch' \
      THIRD_PARTY_NOTICES.md >/dev/null
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
    wincairo_release_tag="$(cat platform/windows-webkit/WEBKIT_RELEASE_TAG)"
    test "$wincairo_release_tag" = \
      "webkitgtk-$(cat WEBKITGTK_MIN_VERSION)"
    wincairo_revision="$(cat platform/windows-webkit/WEBKIT_REVISION)"
    if [[ ! "$wincairo_revision" =~ ^[0-9a-f]{40}$ ]]; then
      echo 'WinCairo WEBKIT_REVISION must contain exactly one lowercase 40-character Git object ID' >&2
      exit 1
    fi
    test -f platform/windows-webkit/patches/xanh-browser-webkit.patch
    grep -F '+WK_EXPORT WKUserScriptRef WKXanhUserScriptCreateWithSourceInWorld' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+WK_EXPORT bool WKXanhUserContentControllerAddScriptMessageHandlerInWorld' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+WK_EXPORT void WKXanhUserContentControllerRemoveScriptMessageHandlerInWorld' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        Ref message = API::ScriptMessage::create(result.toAPI(), page, API::FrameInfo::create(WTF::move(frameInfo)), m_name, contentWorld);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F 'worldName.length() > 128' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+WK_EXPORT bool WKXanhNavigationActionIsRedirect(WKNavigationActionRef action);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+WK_EXPORT bool WKXanhNavigationActionIsTrustedLinkClick(WKNavigationActionRef action);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+WK_EXPORT bool WKXanhNavigationActionTakeUserGesture(WKNavigationActionRef action);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    if (!userInitiatedAction || userInitiatedAction->consumed())' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    userInitiatedAction->setConsumed();' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    return navigationAction->navigationType() == WebCore::NavigationType::LinkClicked && navigationAction->mouseButton() != WebKit::WebMouseEventButton::None;' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    navigationClient.decidePolicyForNavigationAction = decidePolicyForNavigationAction;' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    bool isRedirect = WKXanhNavigationActionIsRedirect(navigationAction);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    bool isTrustedLinkClick = WKXanhNavigationActionIsTrustedLinkClick(navigationAction);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    bool shouldOpenExternal = decision == XanhNavigationPolicy::Decision::openExternal && WKXanhNavigationActionTakeUserGesture(navigationAction);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    wincairo_take_line="$(grep -nF '+    bool shouldOpenExternal = decision == XanhNavigationPolicy::Decision::openExternal && WKXanhNavigationActionTakeUserGesture(navigationAction);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch | cut -d: -f1)"
    wincairo_ignore_line="$(grep -nF '+    WKFramePolicyListenerIgnore(listener);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch | cut -d: -f1)"
    if [[ ! "$wincairo_take_line" =~ ^[0-9]+$ ]] || \
      [[ ! "$wincairo_ignore_line" =~ ^[0-9]+$ ]] || \
      (( wincairo_take_line >= wincairo_ignore_line )); then
      echo 'WinCairo must consume the trusted gesture before resolving the navigation listener' >&2
      exit 1
    fi
    grep -F '+inline constexpr size_t maximumURLCharacters = 8192;' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    test -f platform/windows-webkit/tests/XanhNavigationPolicyTest.cpp
    grep -F '+    navigationClient.webProcessDidTerminate = webProcessDidTerminate;' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    navigationClient.didFinishNavigation = didFinishNavigation;' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+WK_EXPORT bool WKXanhPageCanSafelyRestoreCurrentItem(WKPageRef page);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    return item && XanhProcessRecovery::canSafelyRestoreFrameTree(item->mainFrameState().get());' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+inline constexpr std::size_t maximumFrameStatesToInspect = 4096;' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        for (const auto& child : state->children)' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        WKXanhPageCanSafelyRestoreCurrentItem(page));' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    refuseUnsafeRestore,' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        WKPageReload(page);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    if [[ "$(grep -Fc '+    if (WKPageGetIsControlledByAutomation(page))' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch)" -ne 2 ]]; then
      echo 'WinCairo must query live automation state for termination and authentication' >&2
      exit 1
    fi
    grep -F -- '-    m_isControlledByAutomation = WKPageGetIsControlledByAutomation(page);' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F -- '-    bool m_isControlledByAutomation { false };' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    if grep -F '+    bool m_isControlledByAutomation' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null; then
      echo 'WinCairo must not add a cached automation-state member' >&2
      exit 1
    fi
    if grep -F '+    bool m_currentMainFrameNavigationIsSafeToReplay' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null; then
      echo 'WinCairo must inspect the committed back-forward item instead of a provisional replay cache' >&2
      exit 1
    fi
    grep -F '+        if (m_state != State::available) {' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+            m_state = State::exhausted;' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        if (m_state == State::recoveryLoading)' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    test -f platform/windows-webkit/tests/XanhProcessRecoveryPolicyTest.cpp
    test -f platform/windows-webkit/tests/XanhFrameStateRestorePolicyTest.cpp
    test -f platform/windows-webkit/src/XanhPortableBackup.h
    test -f platform/windows-webkit/src/XanhPortableBackup.cpp
    test -f platform/windows-webkit/tests/portable-backup/CMakeLists.txt
    test -f platform/windows-webkit/tests/portable-backup/XanhPortableBackupTest.cpp
    grep -F '+    XanhPortableBackup.cpp' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+    normaliz' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        case IDM_EXPORT_PORTABLE_BACKUP:' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        case IDM_IMPORT_PORTABLE_BACKUP:' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F '+        MENUITEM "Export encrypted backup...", IDM_EXPORT_PORTABLE_BACKUP' \
      platform/windows-webkit/patches/xanh-browser-webkit.patch >/dev/null
    grep -F "Copy-Item \$portableBackupHeader \$portableBackupHeaderDestination" \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F "Copy-Item \$portableBackupImplementation \$portableBackupImplementationDestination" \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F "Remove-Item \$copiedFile -Force" \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F 'Portable backup implementation SHA-256:' \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F "Get-FileHash \$portableBackupImplementationDestination -Algorithm SHA256" \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F 'Portable-backup sources changed during the WebKit build.' \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F 'ls-files --others --exclude-standard' \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F 'The WebKit checkout has tracked changes after cleanup.' \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F "Remove-Item \$output -Recurse -Force" \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F "\$outputCreatedByThisRun = \$true" \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F "if (\$outputCreatedByThisRun -and \$output -and (Test-Path \$output))" \
      platform/windows-webkit/scripts/Build-XanhBrowserWebKit.ps1 >/dev/null
    grep -F 'IdnToAscii(IDN_USE_STD3_ASCII_RULES' \
      platform/windows-webkit/src/XanhPortableBackup.cpp >/dev/null
    grep -F 'xn--bcher-kva.example' \
      platform/windows-webkit/tests/portable-backup/XanhPortableBackupTest.cpp >/dev/null
    grep -F 'UseStd3AsciiRules = true' \
      platform/windows/src/XanhBrowser.Core/PortableBackup.cs >/dev/null
    grep -F 'https://foo_bar.example/' \
      platform/windows/tests/XanhBrowser.Core.Tests/PortableBackupTests.cs >/dev/null
    grep -F 'windows-wincairo-portable-backup:' \
      .github/workflows/webkit-editions.yml >/dev/null
    grep -F '| Windows WebKit/WinCairo preview | Yes' \
      docs/PORTABLE_BACKUP.md >/dev/null
    grep -F 'WebKit WinCairo source preview' THIRD_PARTY_NOTICES.md >/dev/null
    grep -F "$wincairo_release_tag" THIRD_PARTY_NOTICES.md >/dev/null
    grep -F "$wincairo_revision" THIRD_PARTY_NOTICES.md >/dev/null
    grep -F 'platform/windows-webkit/patches/xanh-browser-webkit.patch' \
      THIRD_PARTY_NOTICES.md >/dev/null
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
    grep -F 'WebView2ProcessRecoveryPolicy.SelectAutomaticTarget' \
      platform/windows/src/XanhBrowser.Windows/BrowserTab.xaml.cs >/dev/null
    grep -F 'automaticRecoveryUsed: true' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'public async Task UpdateLocalTabsAsync(' \
      platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs >/dev/null
    grep -F 'public async Task<IReadOnlyList<FirefoxRemoteTabsDevice>> RemoteTabsAsync(' \
      platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs >/dev/null
    grep -F 'public async Task<IReadOnlyList<FirefoxBookmarkRecord>> BookmarksAsync(' \
      platform/windows/src/XanhBrowser.Core/FirefoxSyncCoordinator.cs >/dev/null
    grep -F 'browser.PageVisited += Browser_PageVisited;' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'coordinator.DeleteBookmarkAsync(selected.Guid' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'coordinator.DeleteHistoryVisitAsync(uri, selected.VisitedAtEpochMillis)' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    grep -F 'clearGeneration != Interlocked.Read(ref _historyClearGeneration)' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs >/dev/null
    sed -n '/ShowRemoteTabsLibraryAsync/,/private static string RemoteDeviceKindLabel/p' \
      platform/windows/src/XanhBrowser.Windows/MainWindow.xaml.cs \
      | grep -F 'AddTab(isPrivate: false, initialUri: uri);' >/dev/null
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
    test -f platform/apple/Sources/XanhBrowserCore/ExternalNavigationPolicy.swift
    test -f platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift
    grep -F 'maximumWebURLBytes = 8_192' \
      platform/apple/Sources/XanhBrowserCore/AddressResolver.swift >/dev/null
    grep -F 'url.user == nil' \
      platform/apple/Sources/XanhBrowserCore/AddressResolver.swift >/dev/null
    grep -F '!containsPercentEncodedControl(value)' \
      platform/apple/Sources/XanhBrowserCore/AddressResolver.swift >/dev/null
    grep -F 'ExternalNavigationPolicy.allows(' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'sourceIsMainFrame: action.source.isMainFrame' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'hasTrustedButtonActivation: hasTrustedButtonActivation' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'isContentRuleListRedirect: action.isContentRuleListRedirect' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'case .webContentProcessTerminated:' \
      platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'request.httpMethod = "GET"' \
      platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift >/dev/null
    grep -F 'cachePolicy: .reloadIgnoringLocalCacheData' \
      platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift >/dev/null
    grep -F 'request.httpBody = nil' \
      platform/apple/Sources/XanhBrowserCore/WebContentProcessRecoveryPolicy.swift >/dev/null
    grep -F 'page.load(request)' platform/apple/App/BrowserModel.swift >/dev/null
    grep -F 'cancelInFlightWebContentRecoveryForBackground()' \
      platform/apple/App/BrowserView.swift >/dev/null
    grep -F 'xanh-browser-macos' platform/apple/project.yml >/dev/null
    grep -F 'xanh-browser-ios' platform/apple/project.yml >/dev/null
    verify_apple_remote_tabs
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
    require_evidence XANH_WPE_GITHUB_ATTESTATION_EVIDENCE
    require_evidence XANH_WPE_HOST_APK_EVIDENCE
    require_evidence XANH_WPE_HOST_TEST_APK_EVIDENCE
    require_evidence XANH_WPE_HOST_16K_EVIDENCE
    require_evidence XANH_WPE_HOST_TOOLCHAIN_EVIDENCE
    wpe_evidence_directory="$(cd "$(dirname "$XANH_WPE_FORK_BUILD_EVIDENCE")" && pwd -P)"
    test "$XANH_WPE_FORK_BUILD_EVIDENCE" -ef \
      "$wpe_evidence_directory/wpe-build-evidence.json"
    test "$XANH_WPE_16K_EVIDENCE" -ef \
      "$wpe_evidence_directory/wpe-16k-evidence.txt"
    test "$XANH_WPE_SBOM_EVIDENCE" -ef \
      "$wpe_evidence_directory/wpeview-sbom.cdx.json"
    test "$XANH_WPE_GITHUB_ATTESTATION_EVIDENCE" -ef \
      "$wpe_evidence_directory/github-attestation.sigstore.json"
    test "$XANH_WPE_HOST_APK_EVIDENCE" -ef \
      "$wpe_evidence_directory/xanh-browser-lite-wpe-debug.apk"
    test "$XANH_WPE_HOST_TEST_APK_EVIDENCE" -ef \
      "$wpe_evidence_directory/xanh-browser-lite-wpe-debug-androidTest.apk"
    test "$XANH_WPE_HOST_16K_EVIDENCE" -ef \
      "$wpe_evidence_directory/xanh-host-16k-evidence.txt"
    test "$XANH_WPE_HOST_TOOLCHAIN_EVIDENCE" -ef \
      "$wpe_evidence_directory/xanh-host-build-environment.txt"
    wpe_artifact="$wpe_evidence_directory/xanh-wpeview-$(cat app-webkit/WPEVIEW_VERSION)-webkit-$(cat app-webkit/wpe-fork/WPE_RUNTIME_VERSION).aar"
    test -f "$wpe_artifact"
    command -v gh >/dev/null
    test "$(wc -c < "$XANH_WPE_GITHUB_ATTESTATION_EVIDENCE")" -le 16777216
    git diff --quiet
    git diff --cached --quiet
    test -z "$(git status --porcelain --untracked-files=all)"
    wpe_source_digest="$(git rev-parse HEAD)"
    for attested_subject in \
      "$XANH_WPE_FORK_BUILD_EVIDENCE" \
      "$XANH_WPE_SBOM_EVIDENCE" \
      "$wpe_artifact" \
      "$XANH_WPE_HOST_APK_EVIDENCE" \
      "$XANH_WPE_HOST_TEST_APK_EVIDENCE" \
      "$XANH_WPE_HOST_16K_EVIDENCE" \
      "$XANH_WPE_HOST_TOOLCHAIN_EVIDENCE"; do
      gh attestation verify "$attested_subject" \
        --bundle "$XANH_WPE_GITHUB_ATTESTATION_EVIDENCE" \
        --repo LamPPKK/midori-core \
        --signer-workflow \
          github.com/LamPPKK/midori-core/.github/workflows/wpe-android-source-build.yml \
        --source-digest "$wpe_source_digest" >/dev/null
    done
    python3 scripts/create_wpe_build_evidence.py \
      --verify-directory "$wpe_evidence_directory"
    ./scripts/verify-android-16k.sh "$wpe_artifact"
    ./scripts/verify-android-16k.sh "$XANH_WPE_HOST_APK_EVIDENCE"
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
