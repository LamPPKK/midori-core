# Xanh WebView architecture

Xanh WebView is the application-owned embedding API for Xanh Browser. It gives
the browser one navigation, lifecycle, profile, permission, script-world and
content-blocking contract while allowing each operating system to use the
backend that can be shipped and serviced safely there.

It is **not** a new rendering engine, an Android system WebView provider, or a
promise that every platform runs identical engine code. The intended end state
is for application code to depend on the Xanh boundary; renderer provenance
remains visible in the UI, build evidence and release artifacts.

The canonical SDK, conformance cases and upstream lock are maintained in
[`LamPPKK/xanh-webview`](https://github.com/LamPPKK/xanh-webview).

## Backend matrix

| Platform | Xanh backend | Current cutover |
| --- | --- | --- |
| Android API 31+ preview | [`LamPPKK/wpe-android`](https://github.com/LamPPKK/wpe-android) | Real WPE backend; source build and device gates remain mandatory |
| Android API 26+ | Serviced Android provider behind `XanhWebView` | Explicit fallback until WPE reaches API/capability parity |
| Windows production target | [`LamPPKK/cef`](https://github.com/LamPPKK/cef) | Planned x64/ARM64 backend; WebView2 remains the fallback during migration |
| Windows x64 laboratory | [`LamPPKK/WebKit`](https://github.com/LamPPKK/WebKit) WinCairo | Source-built preview, not the production SDK |
| Linux desktop | WebKitGTK 6 adapter | SDK seam exists; the current GTK app still constructs `WebKitWebView` directly |
| Linux embedded | WPE WebKit/WPEPlatform adapter | Target backend for kiosk and embedded products |
| macOS | System `WKWebView`/SwiftUI `WebView` adapter | SDK seam exists; the current SwiftUI app still uses `WebView`/`WebPage` directly |
| iOS/iPadOS | System `WKWebView` adapter | Adapter target; not wired into this repository's app, and alternative engines require Apple entitlement |

The WPE Android, WPE Android Cerbero, WebKit, CEF and adblock-rust upstream
networks have corresponding public forks under the `LamPPKK` account. Reviewed
Xanh engine changes live on `xanh/*` branches; exact upstream and fork commits
are pinned by the SDK rather than resolved from a moving branch during release.

## Current integration state

This change introduces Xanh-owned widget boundaries in the two Android Lite
applications. It does not yet migrate the Windows WinUI host away from direct
CoreWebView2 calls, the GTK desktop host away from direct `WebKitWebView`, or
the SwiftUI host away from `WebView`/`WebPage`. The CEF, Linux and Apple modules
in the SDK are adapter seams and conformance targets until those app migrations
land. Their presence must not be read as completed app integration.

## Required API behavior

Every production backend must implement or fail closed on the same set of
operations:

- validate and decide a navigation before bytes are committed;
- expose bounded URL/title/progress/history state;
- provide persistent and ephemeral profiles without cross-profile storage;
- install content blocking atomically before the first protected navigation;
- isolate document-start scripts and typed host messages in a named world;
- require native confirmation for permissions, downloads and external apps;
- report renderer termination once and never replay body-bearing history;
- tear down callbacks, scripts, profiles and native handles deterministically;
- publish backend name, engine version, source revision and capability set.

Missing required capabilities must prevent a production cutover. A backend may
remain a clearly labelled preview or fallback, but it must not advertise a
capability it does not implement.

## Cutover gates

Android WPE cannot replace the API-26 application until it supports the full
device range, multi-profile privacy, downloads/file selection, permission
ownership, renderer recovery, accessibility, 16 KiB native pages and all
credential/content-blocking conformance cases. The current WPE application is
API 31+, arm64/x86_64 and preview-only.

Windows CEF cannot replace WebView2 until both x64 and ARM64 artifacts have
reproducible Chromium/CEF provenance, sandbox/process tests, signed packaging,
codec/license review and the Xanh bridge conformance suite. WinCairo remains a
useful WebKit test backend but upstream does not publish a supported Windows
embedding SDK or redistributable runtime.

Apple uses the system WebKit backend by default. Alternative iOS/iPadOS engines
are out of scope until Xanh qualifies for the relevant regional entitlement
and its engine satisfies Apple's security, conformance and update obligations.

## Upstream references

- [WPE Android](https://github.com/Igalia/wpe-android) and [WPE releases](https://wpewebkit.org/release/)
- [WebKit licensing](https://webkit.org/licensing-webkit/) and [Windows port](https://docs.webkit.org/Ports/WindowsPort.html)
- [CEF source](https://github.com/chromiumembedded/cef) and [supported branches](https://chromiumembedded.github.io/cef/branches_and_building.html)
- [WebView2 distribution](https://learn.microsoft.com/microsoft-edge/webview2/concepts/distribution)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [alternative browser engines](https://developer.apple.com/support/alternative-browser-engines/)
