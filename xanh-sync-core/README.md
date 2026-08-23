# xanh-sync-core

Shared Mozilla Accounts / Firefox Sync contract for Xanh Browser. Production
builds use Mozilla Application Services **155.0** at revision
`c0fd8cea40c9b5dafc6604831f7bd7a8c096d313` and must enable the `mozilla`
feature.

The repository does not assume that this pin remains current. Run
`python3 scripts/verify_application_services_latest.py` from the repository
root with network access before release. CI repeats the check for relevant
changes and weekly; a newer stable tag is a reviewed upgrade that must rerun
interop, FFI, SBOM and security evidence rather than an automatic rewrite.

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

The `fuzz/` package exercises the untrusted bridge envelope, credential context
policy and stable credential C ABI with libFuzzer. It is intentionally portable
and does not enable the Mozilla/NSS backend:

```sh
cargo install cargo-fuzz --version 0.13.2 --locked
cargo fuzz run --fuzz-dir xanh-sync-core/fuzz bridge_message
cargo fuzz run --fuzz-dir xanh-sync-core/fuzz credential_context
cargo fuzz run --fuzz-dir xanh-sync-core/fuzz credential_context_ffi
```

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
sync, local/remote Tabs data, Places bookmark/history data, bounded Logins CRUD
and disconnect) is present in the foreign-language contract; generated files
are build artifacts, not hand-edited source.

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
`delete_history_visit` removes the exact URL and timestamp.
`clear_history` deletes the complete local Places visit range through the
upstream API so the next history Sync can propagate removals. History input is
capped at 8 MiB/1,000 records and output at 8
MiB/500 records. Bookmark mutations are capped at 64 KiB, trees at 16 MiB and
10,000 records, titles at 4,096 UTF-8 bytes and URLs at 8,192 bytes.

## Logins credential bridge

`credentials`, `add_credential`, `update_credential`, `delete_credential` and
`touch_credential` operate on the same encrypted Logins store registered with
the upstream Passwords Sync engine. All five operations require a strict
`CredentialContext`: regular browsing, a native user action, an unlocked vault,
an HTTPS document without userinfo, and canonical same-origin top/frame
origins. The core derives the stored origin and form-action origin from that
validated context; callers cannot supply a broader target. HTTP-auth records
and Firefox records outside this exact-origin HTTPS subset are never returned
to a Xanh fill bridge.

New and updated form credentials use this JSON shape at the C boundary:

```json
{"context":{"document_url":"https://example.com/login","top_frame_origin":"https://example.com","frame_origin":"https://example.com","is_private":false,"user_selected":true},"username_field":"email","password_field":"password","username":"person@example.com","password":"secret"}
```

An update additionally requires `id`. Returned records include `id`, canonical
`origin`/`form_action_origin`, the four form/secret fields and millisecond
creation/password-change/last-use metadata plus `times_used`. Add uses the
upstream add-or-update path so retrying the same origin/form/username does not
create a duplicate. IDs are opaque safe ASCII. Inputs are capped at 64 KiB;
queries return at most 100 validated records and 4 MiB. Usernames are capped at
1,024 UTF-8 bytes, passwords at 4,096, field names at 256 and origins at 8,192.
Embedded NUL is rejected at the shared boundary so NUL-terminated C hosts
cannot observe a silently truncated username or password.

Every returned JSON string and generated-binding record contains plaintext
secret material. Hosts must keep it inside the lifetime of an authenticated
native credential picker, never log/cache it, and release C strings promptly.
This core contract does not itself authorize an injected script: each platform
must additionally validate its current tab ID/navigation nonce in an isolated
world before requesting or filling a selected credential.

`bindgen-context` is a metadata-only workspace member. It enables the pinned
Application Services graph for `cargo metadata`, allowing UniFFI to locate the
upstream Places, Tabs and Logins UDL files embedded in the production library.
It is excluded from the workspace default members, ships no runtime code and
does not change the default feature set of `xanh-sync-core`.
