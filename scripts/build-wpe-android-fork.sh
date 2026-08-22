#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 /path/to/clean/wpe-android-checkout /new/evidence-directory" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

if [[ "$(uname -s)" != Linux ]]; then
  echo "The reproducible WPE Android source build is supported only on Linux" >&2
  exit 2
fi

for command in git java python3 readelf ruby sha256sum tar unifdef unzip; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required build command is missing: $command" >&2
    exit 2
  fi
done
if ! python3 -c 'import distro, sys, venv; assert sys.version_info >= (3, 10)' \
  >/dev/null 2>&1; then
  echo "Python 3.10+ with modules distro and venv is required by the pinned build" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_argument="$1"
output_argument="$2"
if [[ ! -d "$source_argument" ]]; then
  usage
  exit 2
fi
source_root="$(git -C "$source_argument" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$source_root" ]]; then
  echo "WPE Android source is not a Git checkout: $source_argument" >&2
  exit 2
fi
source_root="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$source_root")"
source_argument="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$source_argument")"
if [[ "$source_root" != "$source_argument" ]]; then
  echo "Pass the WPE Android repository root, not a subdirectory" >&2
  exit 2
fi

output="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$output_argument")"
if [[ -e "$output" ]]; then
  echo "Evidence output already exists; refusing to overwrite it: $output" >&2
  exit 2
fi
output_parent="$(dirname "$output")"
mkdir -p "$output_parent"

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" || ! -d "$sdk_root" ]]; then
  echo "ANDROID_SDK_ROOT or ANDROID_HOME must identify an installed Android SDK" >&2
  exit 2
fi
sdk_root="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$sdk_root")"

java_settings="$(java -XshowSettings:properties -version 2>&1)"
if ! grep -Eq '^[[:space:]]*java\.specification\.version = 17$' <<<"$java_settings"; then
  echo "The WPE Android source build requires JDK 17" >&2
  exit 2
fi

android_platform=35
android_build_tools=35.0.0
android_ndk=27.0.12077973
android_cmake=3.31.1
required_sdk_paths=(
  "$sdk_root/platforms/android-$android_platform"
  "$sdk_root/build-tools/$android_build_tools"
  "$sdk_root/ndk/$android_ndk"
  "$sdk_root/cmake/$android_cmake"
)
for required_path in "${required_sdk_paths[@]}"; do
  if [[ ! -d "$required_path" ]]; then
    echo "Required pinned Android SDK component is missing: $required_path" >&2
    exit 2
  fi
done
export ANDROID_SDK_ROOT="$sdk_root"
export ANDROID_HOME="$sdk_root"
export ANDROID_NDK_HOME="$sdk_root/ndk/$android_ndk"

"$root/scripts/verify-wpe-android-fork.sh" "$source_root"

temporary_base="${XANH_WPE_BUILD_TMPDIR:-${TMPDIR:-/tmp}}"
if [[ ! -d "$temporary_base" || ! -w "$temporary_base" ]]; then
  echo "WPE build temporary directory is not writable: $temporary_base" >&2
  exit 2
fi
temporary_root="$(mktemp -d "$temporary_base/xanh-wpe-android-build.XXXXXX")"
export GRADLE_USER_HOME="$temporary_root/gradle-home"
export XDG_CACHE_HOME="$temporary_root/cache"
export CCACHE_DIR="$temporary_root/ccache"
mkdir -m 700 "$GRADLE_USER_HOME" "$XDG_CACHE_HOME" "$CCACHE_DIR"
worktree="$temporary_root/wpe-android"
build_log="$temporary_root/build.log"
build_environment="$temporary_root/build-environment.txt"
alignment_evidence="$temporary_root/wpe-16k-evidence.txt"
upstream_source="$temporary_root/wpe-android-upstream.tar.gz"
cerbero_source="$temporary_root/cerbero-upstream.tar.gz"
staging="$(mktemp -d "$output_parent/.xanh-wpe-evidence.XXXXXX")"

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [[ -d "$temporary_root" ]]; then
    rm -rf "$temporary_root"
  fi
  if [[ -d "$staging" ]]; then
    rm -rf "$staging"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

expected_revision="$(<"$root/app-webkit/wpe-fork/WPE_ANDROID_REVISION")"
expected_cerbero_revision="$(<"$root/app-webkit/wpe-fork/CERBERO_REVISION")"
expected_runtime="$(<"$root/app-webkit/wpe-fork/WPE_RUNTIME_VERSION")"
source_date_epoch="$(git -C "$source_root" show -s --format=%ct "$expected_revision")"
export SOURCE_DATE_EPOCH="$source_date_epoch"

run_logged() {
  working_directory="$1"
  shift
  {
    printf 'RUN'
    printf ' %q' "$@"
    printf '\n'
  } | tee -a "$build_log"
  (
    cd "$working_directory"
    "$@"
  ) 2>&1 | tee -a "$build_log"
}

git clone --no-checkout --no-hardlinks "$source_root" "$worktree"
git -C "$worktree" checkout --detach "$expected_revision"
git -C "$worktree" apply "$root/app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch"
git -C "$worktree" apply --reverse --check \
  "$root/app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch"
git -C "$worktree" diff --check

catalog="$worktree/gradle/libs.versions.toml"
wrapper="$worktree/gradle/wrapper/gradle-wrapper.properties"
grep -Fx "target-android-sdk = \"$android_platform\"" "$catalog" >/dev/null
grep -Fx "android-ndk = \"$android_ndk\"" "$catalog" >/dev/null
grep -Fx "android-sdk-build-tools = \"$android_build_tools\"" "$catalog" >/dev/null
grep -Fx "cmake = \"$android_cmake\"" "$catalog" >/dev/null
grep -Fx 'distributionSha256Sum=7a00d51fb93147819aab76024feece20b6b84e420694101f276be952e08bef03' \
  "$wrapper" >/dev/null

{
  printf 'schema=io.github.lamppkk.xanhbrowser.wpe-build-environment.v1\n'
  printf 'source_date_epoch=%s\n' "$source_date_epoch"
  printf 'wpe_android_revision=%s\n' "$expected_revision"
  printf 'wpe_runtime_version=%s\n' "$expected_runtime"
  printf 'android_platform=%s\n' "$android_platform"
  printf 'android_build_tools=%s\n' "$android_build_tools"
  printf 'android_ndk=%s\n' "$android_ndk"
  printf 'android_cmake=%s\n' "$android_cmake"
  printf 'cerbero_system_bootstrap=false\n'
  printf 'build_cache_scope=job-local-fresh\n'
  uname -a
  if [[ -r /etc/os-release ]]; then
    sed -n 's/^\(ID\|VERSION_ID\)=/os_\1=/p' /etc/os-release
  fi
  git --version
  python3 --version
  java -version 2>&1
  readelf --version | sed -n '1p'
  ruby --version
  unifdef -V 2>&1 || true
  "$sdk_root/cmake/$android_cmake/bin/cmake" --version | sed -n '1p'
  "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version | sed -n '1p'
  sed -n 's/^Pkg.Revision = /ndk_revision=/p' "$ANDROID_NDK_HOME/source.properties"
  sha256sum \
    "$sdk_root/platforms/android-$android_platform/android.jar" \
    "$sdk_root/build-tools/$android_build_tools/aapt2" \
    "$ANDROID_NDK_HOME/source.properties" \
    "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" \
    "$sdk_root/cmake/$android_cmake/bin/cmake"
  "$worktree/gradlew" --version
} >"$build_environment"

run_logged "$worktree" ./tools/scripts/bootstrap.py --build --arch=arm64
run_logged "$worktree" ./tools/scripts/bootstrap.py --build --arch=x86_64
run_logged "$worktree" ./gradlew --no-daemon --stacktrace :wpeview:assembleRelease

aar="$worktree/wpeview/build/outputs/aar/wpeview-release.aar"
if [[ ! -f "$aar" ]]; then
  echo "Expected WPEView release AAR was not produced: $aar" >&2
  exit 1
fi
{
  printf 'RUN %q %q\n' ./scripts/verify-android-16k.sh "$aar"
  (
    cd "$root"
    ./scripts/verify-android-16k.sh "$aar"
  )
} 2>&1 | tee -a "$build_log" "$alignment_evidence"

cerbero="$worktree/build/cerbero"
if [[ ! -x "$cerbero/cerbero-uninstalled" ]]; then
  echo "Pinned Cerbero checkout is missing after the source build" >&2
  exit 1
fi
run_logged "$cerbero" ./cerbero-uninstalled \
  -c config/cross-android-arm64 bundle-source --offline --no-bootstrap wpewebkit

shopt -s nullglob
source_bundles=("$cerbero"/dist/cerbero-*.tar.*)
shopt -u nullglob
if (( ${#source_bundles[@]} != 1 )); then
  echo "Expected exactly one Cerbero corresponding-source bundle; found ${#source_bundles[@]}" >&2
  exit 1
fi

git -C "$worktree" archive --format=tar.gz \
  --prefix="wpe-android-$expected_revision/" \
  --output="$upstream_source" "$expected_revision"
git -C "$cerbero" archive --format=tar.gz \
  --prefix="cerbero-$expected_cerbero_revision/" \
  --output="$cerbero_source" "$expected_cerbero_revision"

python3 "$root/scripts/create_wpe_build_evidence.py" \
  --root "$root" \
  --source "$worktree" \
  --aar "$aar" \
  --upstream-source "$upstream_source" \
  --cerbero-source "$cerbero_source" \
  --corresponding-source "${source_bundles[0]}" \
  --build-environment "$build_environment" \
  --build-log "$build_log" \
  --alignment-evidence "$alignment_evidence" \
  --output "$staging"

python3 -m json.tool "$staging/wpe-build-evidence.json" >/dev/null
python3 -m json.tool "$staging/wpeview-sbom.cdx.json" >/dev/null
python3 "$root/scripts/create_wpe_build_evidence.py" \
  --root "$root" --verify-directory "$staging"
mv --no-clobber --no-target-directory "$staging" "$output"
if [[ -e "$staging" ]]; then
  echo "Evidence output appeared concurrently; refusing to overwrite it: $output" >&2
  exit 1
fi
echo "WPE Android source-build evidence created at $output"
