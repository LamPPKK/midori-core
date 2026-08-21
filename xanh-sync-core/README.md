# xanh-sync-core

Shared Mozilla Accounts / Firefox Sync contract for Xanh Browser. Production
builds use Mozilla Application Services **155.0** at revision
`c0fd8cea40c9b5dafc6604831f7bd7a8c096d313` and must enable the `mozilla`
feature.

The default feature set deliberately builds only the portable policy/state
layer so unit tests do not require NSS. A release that omits `mozilla` must be
rejected by packaging checks.

Security invariants:

- OAuth runs in the system browser with the redirect and PKCE state managed by
  `fxa-client`; credentials are never collected in an embedded web view.
- `FirefoxAccount.to_json()`, scoped keys, access tokens and the local logins
  key are secrets. The host stores them only in OS secure storage.
- Custom Accounts and Token Server endpoints must be HTTPS.
- Password access is denied for HTTP, private browsing, userinfo URLs,
  cross-origin frames, locked vaults and requests without a native user action.
- Engine switches remain local and never write account-global declined state.
- `.xanhbackup` is a separate offline format and must never include account
  state, keys, tokens or passwords.

Native build prerequisites follow Mozilla's NSS instructions. For a pinned
Application Services checkout, build NSS and export `NSS_DIR`/`NSS_STATIC=1`
before running:

The `mozilla` build initializes the pinned `init_rust_components` component
before opening a runtime or generating a local logins key. Embedders do not
need to initialize NSS through a separate Xanh API. Application Services 155
registers Sync engines in process-global registries, so the core enforces one
live production runtime per process. A second open fails until the first
runtime is freed; editions needing profile isolation must use separate
processes.

Linux CI resolves the NSS and NSPR library directories through `pkg-config`.
This deliberately avoids mixing the system libraries with private copies from
an installed Firefox build, which may require a matching `libmozsqlite3`.

```sh
cargo test --manifest-path xanh-sync-core/Cargo.toml
cargo build --release --features mozilla --manifest-path xanh-sync-core/Cargo.toml
```

The release CI reads the UniFFI metadata from that exact native library and
generates both Kotlin and Swift bindings with the locked `bindgen-cli` feature.
This ensures `MozillaSyncRuntime` (OAuth, account state, vault, single-flight
sync, local/remote Tabs data, Places bookmark/history data and disconnect) is
present in the foreign-language contract; generated files are build artifacts,
not hand-edited source.

Platform hosts replace the local Tabs state through `update_local_tabs` before
a Tabs sync, then read remote records grouped by device through `remote_tabs`.
The C equivalents accept/return bounded JSON. The shared core excludes private
tabs, rejects non-HTTP(S) or userinfo URLs and sanitizes untrusted remote URLs.
Remote records are display-only: a host must require an explicit user action
before opening one.

The stable C JSON field names are:

```json
[{"title":"Example","url_history":["https://example.com/"],"icon_url":null,"last_used_epoch_millis":1700000000000,"is_private":false,"is_pinned":false}]
```

The update result is `{"accepted_count":1,"skipped_private_count":0}`.
Remote output is an array of devices with `device_id`, `device_name`,
`device_kind`, `last_modified_epoch_millis` and `tabs`; each tab has `title`,
`url_history`, `icon_url`, `last_used_epoch_millis` and `is_pinned`. Local input
is capped at 4 MiB/500 records, remote output at 8 MiB/500 records, URL history
at 10 entries and each URL at 8,192 bytes.

## Places bookmark and history bridge

`create_bookmark`, `bookmark_tree`, `update_bookmark` and `delete_bookmark`
operate on the same Places database registered with the upstream Bookmarks and
History Sync engines. Well-known root GUIDs are returned by
`bookmark_root_guid`; the C root codes are menu `0`, toolbar `1`, unfiled `2`
and mobile `3`. A new bookmark is encoded as:

```json
{"parent_guid":"unfiled_____","position":null,"kind":"bookmark","title":"Example","url":"https://example.com/","date_added_epoch_millis":1700000000000,"last_modified_epoch_millis":1700000000001,"is_private":false}
```

`is_private` is mandatory and the core rejects every create/update mutation
from private browsing. Delete also takes a mandatory `is_private` argument and
fails closed for private browsing. `kind` is `bookmark`, `folder` or
`separator`. Bookmark URLs are required and
must be canonical HTTP(S) URLs without userinfo; folders cannot have a URL;
separators cannot have a title or URL. An update contains `guid`, optional
`title`, optional `url`, optional `parent_guid`, optional `position` and the
mandatory `is_private` context flag. A null field means “do not change”; an
empty title clears the current title. Bookmark
tree results are pre-order flat records including the requested root, so each
record carries its GUID, parent GUID, position and kind. Places can receive
Firefox bookmarklets and other non-web URLs through Sync. They remain
visible/manageable, but
`is_openable` is false and a host must never navigate them in a web view. Tree
reads use bounded, non-recursive child queries and reject more than 10,000
records before materializing an unbounded Firefox tree.

`record_history` accepts a bounded array of explicit visit records and returns
accepted/private-skipped counts. The core validates the full array before the
first write and never sends private visits to Places:

```json
[{"url":"https://example.com/","title":"Example","visited_at_epoch_millis":1700000000000,"transition":"typed","is_private":false}]
```

Transitions are `link`, `typed`, `bookmark`, `redirect-permanent`,
`redirect-temporary`, `download` and `reload`; subframe/embed observations are
not part of the public write contract. Recording is idempotent by canonical URL
plus millisecond timestamp, so retrying a batch after an error cannot duplicate
visits that Places already committed. `recent_history` returns only non-hidden
canonical HTTP(S) visits and includes the upstream `is_remote` bit;
`delete_history_visit` removes the exact URL and timestamp. History input is
capped at 8 MiB/1,000 records and output at 8
MiB/500 records. Bookmark mutations are capped at 64 KiB, trees at 16 MiB and
10,000 records, titles at 4,096 UTF-8 bytes and URLs at 8,192 bytes.

`bindgen-context` is a metadata-only workspace member. It enables the pinned
Application Services graph for `cargo metadata`, allowing UniFFI to locate the
upstream Places, Tabs and Logins UDL files embedded in the production library.
It is excluded from the workspace default members, ships no runtime code and
does not change the default feature set of `xanh-sync-core`.
