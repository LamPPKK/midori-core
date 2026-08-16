#!/bin/sh
set -eu

version="1.0.0"
archive="xanh-browser-${version}.tar.xz"
prefix="xanh-browser-${version}/"

if [ -n "$(git status --porcelain)" ]; then
  printf '%s\n' 'Refusing to archive a dirty worktree.' >&2
  exit 1
fi

git archive --format=tar --prefix="$prefix" HEAD \
  | xz --threads=1 --check=crc32 --lzma2=preset=9e,dict=64MiB --stdout > "$archive"
sha256sum "$archive" > "${archive}.sha256"

if [ -n "${XANH_RELEASE_GPG_KEY:-}" ]; then
  gpg --batch --local-user "$XANH_RELEASE_GPG_KEY" --armor --detach-sign "$archive"
fi

printf '%s\n' "$archive" "${archive}.sha256"
