# Xanh Browser portable backup

The `.xanhbackup` format is the provider-neutral sync boundary for Xanh
Browser. Applications read and write it through the operating-system file
picker; they do not authenticate directly to a cloud or Git service.

## Supported editions

| Edition | Export | Import |
| --- | --- | --- |
| Android full (System WebView) | Yes, up to 50 regular tabs | Yes, appends regular tabs |
| Android Lite (System WebView) | Yes | Yes |
| Android Lite WebKit preview | Yes | Yes |
| Windows (WebView2) | Yes, all regular tabs | Yes, appends regular tabs |
| Windows WebKit/WinCairo preview | Not yet | Not yet |

The WinCairo UI is maintained as a patch over a pinned upstream MiniBrowser.
Portable backup support is therefore a release gate for that preview rather
than an unreviewed native bridge added to the first engine build.

## Provider workflow

1. Choose **Export encrypted backup** and enter a unique password of at least
   eight characters.
2. In the system picker, save the file to the desired provider:
   - Android: Google Drive or another installed Documents provider.
   - Windows: an OS-backed-up Documents folder, OneDrive, Google Drive for
     desktop, or a Git working tree.
3. Let that provider finish uploading or committing the binary file.
4. On the other device, choose **Import encrypted backup**, select the same
   file and enter the same password.

Backups are snapshots, not mergeable text. Avoid concurrent writers. If a
provider creates a conflict copy, compare file timestamps in the provider and
import the intended snapshot. Keep Git repositories private even though the
payload is encrypted, and never commit the password or signing keys. The Xanh
Browser source repositories ignore `*.xanhbackup`; use a separate private sync
repository instead of mixing personal snapshots with application source.

Android application auto-backup remains disabled. Browser stores may contain
cookies, tokens and other private state that should not silently cross devices.
The explicit encrypted file is the only supported OS/cloud backup surface.

## Included and excluded data

Version 1 includes:

- creation time in UTC milliseconds;
- source edition identifier;
- up to 50 valid HTTP(S) tab URLs;
- selected regular-tab index;
- desktop-site mode.

It never includes cookies, passwords, HTTP authentication, form data, cache,
local storage, service workers, downloads, private tabs or signing material.
Encoded files are limited to 1 MiB before parsing.

## Cryptographic envelope

All integers are unsigned or non-negative big-endian values. Strings are
length-prefixed UTF-8.

| Field | Encoding |
| --- | --- |
| Magic | 8 bytes: `XANHBK1\0` |
| Envelope version | 32-bit integer, currently `1` |
| PBKDF2 iterations | 32-bit integer, currently `210000` |
| Salt | 16 random bytes |
| AES-GCM nonce | 12 random bytes |
| Encrypted length | 32-bit integer |
| Ciphertext and tag | AES-256-GCM, 16-byte tag |

The 256-bit key is derived with PBKDF2-HMAC-SHA256. AES-GCM authenticates the
entire encrypted payload. Import fails closed for a wrong password, tampering,
unsupported versions, malformed UTF-8, trailing bytes or unsafe URLs.

Kotlin and C# tests share a fixed golden vector so a backup produced by one
platform must decode byte-for-byte on the other. Random salts and nonces are
used for real exports; the fixed values exist only in tests.

## Compatibility rules

- Readers must reject unknown envelope and payload versions.
- Writers must never reuse a nonce with the same derived key.
- New optional settings require a new defined flags bit; unknown bits fail.
- Changes that alter field order or encoding require a new payload version and
  migration tests in both implementations.
- Import must validate every URL again before navigation.
