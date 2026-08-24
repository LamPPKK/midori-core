# Xanh Adblock Core

`xanh-adblock-core` is Xanh Browser's native, cross-platform network-filtering
boundary. It embeds Brave's MPL-2.0 `adblock-rust` engine and exposes a small
Rust API plus a stable C ABI for Linux, Apple, Windows and Android hosts.

The dependency is pinned to `adblock-rust` 0.13.3. Default features are
disabled deliberately: Xanh enables domain resolution and full regular
expressions, but omits `single-thread` so one immutable engine can safely serve
concurrent WebView request callbacks.

## Initial scope

- ABP/EasyList/uBO-style network block and exception rules.
- Thread-safe request matching.
- Conversion to WebKit content-blocking JSON, including convertible cosmetic
  rules.
- Bounded C ABI inputs and thread-local diagnostics.

`filters/xanh-baseline.txt` is a small Xanh-maintained MPL-2.0 offline
baseline. Hosts can construct it through `xanh_adblock_engine_create_default`
or compile it for WebKit through
`xanh_adblock_compile_webkit_default_json`. It is intentionally not presented
as EasyList or uBlock Origin's default list.

The host owns list download/update policy and atomically replaces an engine
after parsing a new list. Serialized engine data is only a cache: raw filter
text must remain available because adblock-rust does not guarantee cache
compatibility across minor versions.

Redirect resources, CSP, `removeparam`, procedural cosmetics and scriptlets
are not wired into Xanh Browser hosts yet. WebKit conversion silently cannot
represent several of these rule classes, so release artifacts must record the
conversion coverage of their pinned list snapshot.
