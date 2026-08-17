#!/usr/bin/env bash
set -euo pipefail

base_aab="${1:?usage: verify-lite-sync-size.sh BASE_ONLY_AAB WITH_SYNC_AAB}"
sync_aab="${2:?usage: verify-lite-sync-size.sh BASE_ONLY_AAB WITH_SYNC_AAB}"
max_growth=$((1024 * 1024))

test -f "$base_aab"
test -f "$sync_aab"

module_size() {
  unzip -l "$1" 'base/*' | awk '/^[[:space:]]*[0-9]+[[:space:]]/ { total += $1 } END { print total + 0 }'
}

base_size="$(module_size "$base_aab")"
sync_base_size="$(module_size "$sync_aab")"
growth=$((sync_base_size - base_size))

if (( growth > max_growth )); then
  echo "Lite base grew by ${growth} bytes; maximum is ${max_growth}" >&2
  exit 1
fi

unzip -Z1 "$sync_aab" | grep -Fx 'sync_feature/dex/classes.dex' >/dev/null
unzip -Z1 "$sync_aab" | grep -Fx 'sync_feature/lib/arm64-v8a/libmegazord.so' >/dev/null

if unzip -Z1 "$sync_aab" | grep -E '^base/lib/[^/]+/(libmegazord|libnss3|libxul)\.so$'; then
  echo 'Application Services native libraries must not be packaged in the Lite base module' >&2
  exit 1
fi

if unzip -Z1 "$sync_aab" | grep -E '^sync_feature/lib/(armeabi|mips|mips64)/'; then
  echo 'Unsupported legacy ABI found in the on-demand Sync module' >&2
  exit 1
fi

echo "Lite Sync base growth verified: ${growth} bytes (${base_size} -> ${sync_base_size})"
