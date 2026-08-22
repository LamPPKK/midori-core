#!/usr/bin/env bash
set -euo pipefail

input="${1:-}"
if [[ -z "$input" || ! -e "$input" ]]; then
  echo "Usage: $0 /path/to/artifact.aar-or-apk-or-aab-or-native-directory" >&2
  exit 2
fi

if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  readelf_tool="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -type f -name llvm-readelf -perm -111 -print -quit)"
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
  unzip -qq "$input" -d "$work/artifact"
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
