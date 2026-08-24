#!/usr/bin/env bash
set -euo pipefail

input="${1:-}"
if [[ -z "$input" || ! -e "$input" ]]; then
  echo "Usage: $0 /path/to/artifact.aar-or-apk-or-aab-or-native-directory" >&2
  exit 2
fi

if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  readelf_tool="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
    \( -type f -o -type l \) -name llvm-readelf -perm -111 -print -quit)"
else
  readelf_tool=""
fi
if [[ -z "$readelf_tool" ]]; then
  readelf_tool="$(command -v llvm-readelf || command -v readelf || true)"
fi
if [[ -z "$readelf_tool" ]]; then
  echo "llvm-readelf or readelf is required" >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/xanh-android-16k.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ -d "$input" ]]; then
  search_root="$input"
elif [[ "$input" == *.aar || "$input" == *.apk || "$input" == *.aab || "$input" == *.zip ]]; then
  python3 - "$input" "$work/artifact" <<'PY'
import shutil
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

archive_path = Path(sys.argv[1])
output = Path(sys.argv[2])
maximum_entries = 100_000
maximum_expanded_bytes = 16 * 1024 * 1024 * 1024
names: set[str] = set()
expanded_bytes = 0

try:
    archive = zipfile.ZipFile(archive_path)
except (OSError, zipfile.BadZipFile) as error:
    raise SystemExit(f"Cannot open Android archive: {error}") from error

with archive:
    infos = archive.infolist()
    if not infos or len(infos) > maximum_entries:
        raise SystemExit("Android archive entry count is empty or exceeds 100,000")
    for info in infos:
        name = info.filename
        normalized = name[:-1] if name.endswith("/") else name
        if (
            not normalized
            or "\x00" in name
            or "\\" in name
            or name.startswith("/")
            or any(part in ("", ".", "..") for part in normalized.split("/"))
        ):
            raise SystemExit(f"Unsafe Android archive path: {name!r}")
        if name in names:
            raise SystemExit(f"Duplicate Android archive path: {name}")
        names.add(name)
        if info.is_dir():
            continue
        if stat.S_ISLNK(info.external_attr >> 16):
            raise SystemExit(f"Symbolic link is forbidden in Android archive: {name}")
        expanded_bytes += info.file_size
        if expanded_bytes > maximum_expanded_bytes:
            raise SystemExit("Android archive expands beyond the 16 GiB safety limit")
        if not name.endswith(".so"):
            continue
        destination = output.joinpath(*PurePosixPath(name).parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(info) as source, destination.open("xb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
        if destination.stat().st_size != info.file_size:
            raise SystemExit(f"Truncated native library in Android archive: {name}")
PY
  search_root="$work/artifact"
elif [[ "$input" == *.so ]]; then
  mkdir -p "$work/artifact"
  cp "$input" "$work/artifact/library.so"
  search_root="$work/artifact"
else
  echo "Unsupported input: $input" >&2
  exit 2
fi

checked=0
while IFS= read -r -d '' library; do
  checked=$((checked + 1))
  load_segments=0
  while IFS= read -r alignment; do
    load_segments=$((load_segments + 1))
    hex="${alignment#0x}"
    if [[ ! "$hex" =~ ^[0-9A-Fa-f]+$ ]]; then
      echo "Cannot parse LOAD alignment '$alignment' in $library" >&2
      exit 1
    fi
    if (( 16#$hex < 16384 )); then
      echo "Native library is not 16 KiB aligned: $library ($alignment)" >&2
      exit 1
    fi
  done < <("$readelf_tool" -lW "$library" | awk '$1 == "LOAD" { print $NF }')
  if (( load_segments == 0 )); then
    echo "No ELF LOAD segments found in $library" >&2
    exit 1
  fi
done < <(find "$search_root" -type f -name '*.so' -print0)

if (( checked == 0 )); then
  echo "No native libraries found in $input" >&2
  exit 1
fi

echo "Verified 16 KiB ELF alignment for $checked native libraries"
