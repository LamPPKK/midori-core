#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple


OFFICIAL_REPOSITORY = "https://github.com/brave/adblock-rust.git"
OFFICIAL_SOURCE = "https://github.com/brave/adblock-rust"
LOCK_PATH = Path("xanh-adblock-core/ADBLOCK_RUST.lock")
MAX_TAG_LIST_BYTES = 8 * 1024 * 1024
MAX_TEXT_FILE_BYTES = 64 * 1024 * 1024
SHA1_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SEMVER_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
TAG_PATTERN = re.compile(
    r"^refs/tags/v(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)(\^\{\})?$"
)
EXPECTED_FEATURES = {
    "content-blocking",
    "embedded-domain-resolver",
    "full-regex-handling",
}
EXPECTED_LOCK_KEYS = {
    "version",
    "tag",
    "revision",
    "source",
    "license",
    "crate_checksum",
}


class VerificationError(RuntimeError):
    pass


class StableRelease(NamedTuple):
    version: tuple[int, int, int]
    text: str
    tag: str
    revision: str


def _record_revision(
    revisions: dict[str, dict[str, str]], tag: str, kind: str, revision: str
) -> None:
    values = revisions.setdefault(tag, {})
    previous = values.get(kind)
    if previous is not None and previous != revision:
        raise VerificationError(f"conflicting revisions for {tag} ({kind})")
    values[kind] = revision


def latest_stable_release(tag_list: str) -> StableRelease:
    if len(tag_list.encode("utf-8")) > MAX_TAG_LIST_BYTES:
        raise VerificationError("upstream tag list exceeds the 8 MiB safety limit")

    revisions: dict[str, dict[str, str]] = {}
    stable: dict[tuple[int, int, int], str] = {}
    for line_number, line in enumerate(tag_list.splitlines(), start=1):
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 2:
            raise VerificationError(f"malformed ls-remote output at line {line_number}")
        revision, ref = fields
        if SHA1_PATTERN.fullmatch(revision) is None:
            raise VerificationError(f"invalid Git object ID at line {line_number}")
        if not ref.startswith("refs/tags/v"):
            raise VerificationError(f"unexpected Git ref at line {line_number}")
        match = TAG_PATTERN.fullmatch(ref)
        if match is None:
            # Ignore prereleases and historical non-semver tags.
            continue

        version = tuple(int(part) for part in match.group(1, 2, 3))
        text = ".".join(str(part) for part in version)
        tag = f"v{text}"
        previous = stable.get(version)
        if previous is not None and previous != tag:
            raise VerificationError(f"duplicate normalized stable version: {tag}")
        stable[version] = tag
        kind = "peeled" if match.group(4) else "direct"
        _record_revision(revisions, tag, kind, revision)

    if not stable:
        raise VerificationError("official tag list contains no stable adblock-rust release")
    version = max(stable)
    tag = stable[version]
    values = revisions[tag]
    revision = values.get("peeled", values.get("direct"))
    if revision is None:
        raise VerificationError(f"no revision found for {tag}")
    return StableRelease(version, tag.removeprefix("v"), tag, revision)


def _read_bytes(path: Path, limit: int = MAX_TEXT_FILE_BYTES) -> bytes:
    try:
        if path.is_symlink() or not path.is_file():
            raise VerificationError(f"{path} must be a regular file")
        with path.open("rb") as stream:
            contents = stream.read(limit + 1)
    except OSError as error:
        raise VerificationError(f"cannot read {path}: {error}") from error
    if len(contents) > limit:
        raise VerificationError(f"{path} exceeds the {limit}-byte safety limit")
    return contents


def _read_text(path: Path, limit: int = MAX_TEXT_FILE_BYTES) -> str:
    try:
        return _read_bytes(path, limit).decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{path} is not valid UTF-8") from error


def read_lock(path: Path) -> dict[str, str]:
    contents = _read_text(path, 4096)
    values: dict[str, str] = {}
    for line_number, line in enumerate(contents.splitlines(), start=1):
        fields = line.split("=", 1)
        if len(fields) != 2 or not all(fields):
            raise VerificationError(f"malformed adblock-rust lock line {line_number}")
        key, value = fields
        if key in values:
            raise VerificationError(f"duplicate adblock-rust lock key: {key}")
        values[key] = value
    if set(values) != EXPECTED_LOCK_KEYS or len(contents.splitlines()) != len(
        EXPECTED_LOCK_KEYS
    ):
        raise VerificationError("adblock-rust lock has unexpected or missing keys")
    if SEMVER_PATTERN.fullmatch(values["version"]) is None:
        raise VerificationError("adblock-rust lock version is not exact semver")
    if values["tag"] != f'v{values["version"]}':
        raise VerificationError("adblock-rust lock tag does not match its version")
    if SHA1_PATTERN.fullmatch(values["revision"]) is None:
        raise VerificationError("adblock-rust revision must be lowercase 40-hex")
    if SHA256_PATTERN.fullmatch(values["crate_checksum"]) is None:
        raise VerificationError("adblock-rust crate checksum must be lowercase SHA-256")
    if values["source"] != OFFICIAL_SOURCE:
        raise VerificationError("adblock-rust lock uses an unofficial source")
    if values["license"] != "MPL-2.0":
        raise VerificationError("adblock-rust lock must retain the MPL-2.0 license")
    return values


def _verify_manifest(root: Path, version: str) -> None:
    manifest_path = root / "xanh-adblock-core/Cargo.toml"
    contents = _read_text(manifest_path)
    sections = re.findall(
        r"(?ms)^\[dependencies\]\s*$\n(?P<body>.*?)(?=^\[[^\n]+\]\s*$|\Z)",
        contents,
    )
    if len(sections) != 1:
        raise VerificationError("Cargo manifest must contain one dependencies section")
    matches = re.findall(
        r"(?m)^adblock\s*=\s*\{(?P<fields>[^}]*)\}\s*$", sections[0]
    )
    if len(matches) != 1 or len(re.findall(r"(?m)^adblock\s*=", contents)) != 1:
        raise VerificationError("adblock dependency must use an exact table pin")
    fields = matches[0]
    versions = re.findall(r'\bversion\s*=\s*"([^"]+)"', fields)
    defaults = re.findall(r"\bdefault-features\s*=\s*(true|false)", fields)
    feature_blocks = re.findall(r"(?ms)\bfeatures\s*=\s*\[(.*?)\]", fields)
    if versions != [f"={version}"]:
        raise VerificationError("adblock crate version is not exact")
    if defaults != ["false"]:
        raise VerificationError("adblock default features must stay disabled")
    if len(feature_blocks) != 1:
        raise VerificationError("adblock feature list must appear exactly once")
    features = re.findall(r'"([a-z0-9-]+)"', feature_blocks[0])
    if len(features) != len(set(features)) or set(features) != EXPECTED_FEATURES:
        raise VerificationError("adblock feature set changed without review")
    if "single-thread" in features:
        raise VerificationError("adblock single-thread mode is unsafe for concurrent hosts")
    if re.search(r"\b(?:git|path|branch|tag|package)\s*=", fields):
        raise VerificationError("adblock dependency contains an unreviewed alternate source")


def _verify_cargo_lock(root: Path, version: str, checksum: str) -> None:
    contents = _read_text(root / "xanh-adblock-core/Cargo.lock")
    packages = re.findall(
        r"(?ms)^\[\[package\]\]\s*\n(?P<body>.*?)(?=^\[\[package\]\]|\Z)",
        contents,
    )
    matches = [
        package
        for package in packages
        if re.search(r'(?m)^name = "adblock"$', package)
    ]
    if len(matches) != 1:
        raise VerificationError("Cargo.lock must contain one adblock package")
    package = matches[0]
    required = (
        f'version = "{version}"',
        'source = "registry+https://github.com/rust-lang/crates.io-index"',
        f'checksum = "{checksum}"',
    )
    if any(package.count(value) != 1 for value in required):
        raise VerificationError("Cargo.lock adblock closure does not match the reviewed crate")


def _verify_constants_and_notice(root: Path, lock: dict[str, str]) -> None:
    library = _read_text(root / "xanh-adblock-core/src/lib.rs")
    required_constants = (
        f'pub const ADBLOCK_RUST_VERSION: &str = "{lock["version"]}";',
        f'pub const ADBLOCK_RUST_REVISION: &str = "{lock["revision"]}";',
    )
    if any(library.count(value) != 1 for value in required_constants):
        raise VerificationError("Rust adblock-rust identity constants are stale")

    notice = _read_text(root / "THIRD_PARTY_NOTICES.md")
    required_notice = (
        f'## Brave adblock-rust {lock["version"]}',
        f'`{lock["revision"]}`',
        f'releases/tag/{lock["tag"]}',
        lock["crate_checksum"],
    )
    if any(value not in notice for value in required_notice):
        raise VerificationError("adblock-rust third-party notice is stale")


def verify_project(root: Path, tag_list: str) -> StableRelease:
    root = root.resolve()
    release = latest_stable_release(tag_list)
    lock = read_lock(root / LOCK_PATH)
    if lock["version"] != release.text or lock["tag"] != release.tag:
        raise VerificationError(
            f"adblock-rust pin {lock['tag']} is stale; latest stable is {release.tag}"
        )
    if lock["revision"] != release.revision:
        raise VerificationError(
            f"adblock-rust revision does not match official {release.tag}"
        )
    _verify_manifest(root, release.text)
    _verify_cargo_lock(root, release.text, lock["crate_checksum"])
    _verify_constants_and_notice(root, lock)
    return release


def fetch_official_tags() -> str:
    try:
        completed = subprocess.run(
            ["git", "ls-remote", "--tags", OFFICIAL_REPOSITORY, "refs/tags/v*"],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError(f"cannot query official adblock-rust tags: {error}") from error
    if completed.returncode:
        detail = completed.stderr.strip() or f"git exited with {completed.returncode}"
        raise VerificationError(f"cannot query official adblock-rust tags: {detail}")
    return completed.stdout


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail when Xanh's adblock-rust pin is not Brave's latest stable tag."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="midori-core repository root",
    )
    parser.add_argument(
        "--tags-file",
        type=Path,
        help="read git ls-remote output from a fixture instead of the network",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        tag_list = (
            _read_text(arguments.tags_file, MAX_TAG_LIST_BYTES)
            if arguments.tags_file
            else fetch_official_tags()
        )
        release = verify_project(arguments.root, tag_list)
    except VerificationError as error:
        print(f"adblock-rust verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"Verified latest stable adblock-rust {release.text} at {release.revision}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
