#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output="${1:-}"
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"

if [[ -z "$output" || "$output" != /* ]]; then
  echo "Usage: ANDROID_NDK_HOME=/absolute/ndk $0 /absolute/output-directory" >&2
  exit 2
fi
if [[ -z "$ndk" || "$ndk" != /* || ! -f "$ndk/source.properties" ]]; then
  echo "ANDROID_NDK_HOME must identify an absolute Android NDK directory" >&2
  exit 2
fi
if [[ -e "$output" ]]; then
  echo "Output path already exists: $output" >&2
  exit 2
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) host_tag=linux-x86_64 ;;
  Darwin-x86_64|Darwin-arm64) host_tag=darwin-x86_64 ;;
  *) echo "Unsupported Android cross-build host" >&2; exit 2 ;;
esac

toolchain="$ndk/toolchains/llvm/prebuilt/$host_tag"
readelf_tool="$toolchain/bin/llvm-readelf"
if [[ ! -x "$readelf_tool" ]]; then
  echo "Android NDK LLVM tools are unavailable for $host_tag" >&2
  exit 2
fi
if [[ "$(rustc --version)" != rustc\ 1.97.1\ * ]]; then
  echo "Rust 1.97.1 is required for the Android adblock artifact" >&2
  exit 2
fi
ndk_revision="$(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' "$ndk/source.properties")"
if [[ "$ndk_revision" != "29.0.14206865" ]]; then
  echo "Android NDK 29.0.14206865 is required (found $ndk_revision)" >&2
  exit 2
fi

mkdir -p "$output"
trap 'if [[ -n "${output:-}" && -d "$output" && ! -f "$output/.complete" ]]; then rm -rf "$output"; fi' EXIT

build_one() {
  local rust_target="$1"
  local android_abi="$2"
  local clang_name="$3"
  local linker="$toolchain/bin/$clang_name"
  local linker_variable
  local library="$root/xanh-adblock-core/target/$rust_target/release/libxanh_adblock_core.so"

  linker_variable="CARGO_TARGET_$(printf '%s' "$rust_target" | tr '[:lower:]-' '[:upper:]_')_LINKER"
  if [[ ! -x "$linker" ]]; then
    echo "Missing Android linker: $linker" >&2
    exit 2
  fi
  env "$linker_variable=$linker" \
    CARGO_ENCODED_RUSTFLAGS="-Clink-arg=-Wl,-z,max-page-size=16384" \
    cargo build --locked --release \
      --manifest-path "$root/xanh-adblock-core/Cargo.toml" \
      --target "$rust_target"
  install -d -m 0755 "$output/$android_abi"
  install -m 0644 "$library" "$output/$android_abi/libxanh_adblock_core.so"
}

build_one aarch64-linux-android arm64-v8a aarch64-linux-android26-clang
build_one armv7-linux-androideabi armeabi-v7a armv7a-linux-androideabi26-clang
build_one x86_64-linux-android x86_64 x86_64-linux-android26-clang

for abi in arm64-v8a armeabi-v7a x86_64; do
  case "$abi" in
    arm64-v8a) expected_machine=AArch64 ;;
    armeabi-v7a) expected_machine=ARM ;;
    x86_64) expected_machine="Advanced Micro Devices X86-64" ;;
  esac
  library="$output/$abi/libxanh_adblock_core.so"
  machine="$($readelf_tool -h "$library" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
  if [[ "$machine" != "$expected_machine" ]]; then
    echo "Unexpected ELF machine for $abi: $machine" >&2
    exit 1
  fi
  symbols="$($readelf_tool -Ws "$library")"
  for symbol in \
    xanh_adblock_core_version \
    xanh_adblock_engine_create_default \
    xanh_adblock_engine_should_block \
    xanh_adblock_engine_free; do
    if ! grep -Eq "[[:space:]]${symbol}$" <<<"$symbols"; then
      echo "Missing native adblock export in $abi: $symbol" >&2
      exit 1
    fi
  done
done

PATH="$toolchain/bin:$PATH" ANDROID_NDK_HOME="$ndk" \
  "$root/scripts/verify-android-16k.sh" "$output"
if command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1" | awk '{ print $1 }'; }
else
  hash_file() { shasum -a 256 "$1" | awk '{ print $1 }'; }
fi
{
  echo 'format=1'
  echo 'core_version=1.0.0-alpha.1'
  echo 'adblock_rust_version=0.13.3'
  echo 'adblock_rust_revision=886d45dcf5283ce8eddc6d961e7dd27966ab23f2'
  echo 'rust_version=1.97.1'
  echo "ndk_version=$ndk_revision"
  echo 'android_api=26'
  echo "core_git_revision=$(git -C "$root" rev-parse HEAD)"
  for abi in arm64-v8a armeabi-v7a x86_64; do
    library="$output/$abi/libxanh_adblock_core.so"
    echo "sha256.$abi=$(hash_file "$library")"
  done
} >"$output/ADBLOCK_CORE.manifest"
touch "$output/.complete"
echo "Built bounded adblock-rust Android libraries in $output"
