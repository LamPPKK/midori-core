#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple


OFFICIAL_REPOSITORY = "https://github.com/mozilla/application-services.git"
OFFICIAL_SOURCE = "https://github.com/mozilla/application-services"
OFFICIAL_MAVEN_REPOSITORY = "https://maven.mozilla.org/maven2"
LOCK_PATH = Path("xanh-sync-core/APPLICATION_SERVICES.lock")
MAX_TAG_LIST_BYTES = 8 * 1024 * 1024
MAX_TEXT_FILE_BYTES = 8 * 1024 * 1024
SHA1_PATTERN = re.compile(r"^[0-9a-f]{40}$")
VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?$"
)
TAG_PATTERN = re.compile(
    r"^refs/tags/v"
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:\.(0|[1-9][0-9]*))?"
    r"(\^\{\})?$"
)
EXPECTED_COMPONENTS = {
    "fxa-client",
    "init_rust_components",
    "logins",
    "mozbuild",
    "places",
    "sync_manager",
    "tabs",
}
EXPECTED_LOCK_KEYS = {
    "version",
    "tag",
    "revision",
    "release_date",
    "license",
    "maven_repository",
    "source",
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
        if not SHA1_PATTERN.fullmatch(revision):
            raise VerificationError(f"invalid Git object ID at line {line_number}")
        if not ref.startswith("refs/tags/v"):
            raise VerificationError(f"unexpected Git ref at line {line_number}")
        match = TAG_PATTERN.fullmatch(ref)
        if match is None:
            # Mozilla also publishes prerelease and historical non-semver tags.
            continue

        version = tuple(int(part or 0) for part in match.group(1, 2, 3))
        text = f"{version[0]}.{version[1]}"
        if match.group(3) is not None:
            text += f".{version[2]}"
        tag = f"v{text}"
        previous_tag = stable.get(version)
        if previous_tag is not None and previous_tag != tag:
            raise VerificationError(
                f"duplicate normalized stable version: {previous_tag} and {tag}"
            )
        stable[version] = tag
        kind = "peeled" if match.group(4) else "direct"
        _record_revision(revisions, tag, kind, revision)

    if not stable:
        raise VerificationError(
            "official tag list contains no stable Application Services release"
        )
    version = max(stable)
    tag = stable[version]
    values = revisions[tag]
    revision = values.get("peeled", values.get("direct"))
    if revision is None:
        raise VerificationError(f"no revision found for {tag}")
    return StableRelease(version, tag.removeprefix("v"), tag, revision)


def _read_bounded(path: Path, limit: int = MAX_TEXT_FILE_BYTES) -> str:
    try:
        if path.is_symlink() or not path.is_file():
            raise VerificationError(f"{path} must be a regular file")
        with path.open("rb") as stream:
            contents = stream.read(limit + 1)
    except OSError as error:
        raise VerificationError(f"cannot read {path}: {error}") from error
    if len(contents) > limit:
        raise VerificationError(f"{path} exceeds the {limit}-byte safety limit")
    try:
        return contents.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{path} is not valid UTF-8") from error


def read_lock(path: Path) -> dict[str, str]:
    contents = _read_bounded(path, 4096)
    values: dict[str, str] = {}
    for line_number, line in enumerate(contents.splitlines(), start=1):
        fields = line.split("=", 1)
        if len(fields) != 2 or not all(fields):
            raise VerificationError(f"malformed Application Services lock line {line_number}")
        key, value = fields
        if key in values:
            raise VerificationError(f"duplicate Application Services lock key: {key}")
        values[key] = value
    if set(values) != EXPECTED_LOCK_KEYS or len(contents.splitlines()) != len(
        EXPECTED_LOCK_KEYS
    ):
        raise VerificationError("Application Services lock has unexpected or missing keys")
    if VERSION_PATTERN.fullmatch(values["version"]) is None:
        raise VerificationError("Application Services lock version is not exact semver")
    if values["tag"] != f'v{values["version"]}':
        raise VerificationError("Application Services lock tag does not match its version")
    if not SHA1_PATTERN.fullmatch(values["revision"]):
        raise VerificationError("Application Services revision must be lowercase 40-hex")
    try:
        release_date = datetime.date.fromisoformat(values["release_date"])
    except ValueError as error:
        raise VerificationError("Application Services release date is invalid") from error
    if release_date.isoformat() != values["release_date"]:
        raise VerificationError("Application Services release date is not canonical")
    if values["license"] != "MPL-2.0":
        raise VerificationError("Application Services lock must retain the MPL-2.0 license")
    if values["source"] != OFFICIAL_SOURCE:
        raise VerificationError("Application Services lock uses an unofficial source")
    if values["maven_repository"] != OFFICIAL_MAVEN_REPOSITORY:
        raise VerificationError("Application Services lock uses an unofficial Maven repository")
    return values


def _verify_cargo_manifest(root: Path, revision: str) -> None:
    path = root / "xanh-sync-core/Cargo.toml"
    contents = _read_bounded(path)
    components: set[str] = set()
    for line in contents.splitlines():
        if OFFICIAL_SOURCE not in line:
            continue
        match = re.fullmatch(r"\s*([A-Za-z0-9_-]+)\s*=\s*\{(.*)\}\s*", line)
        if match is None:
            raise VerificationError(f"unreviewed Application Services dependency syntax in {path}")
        name, fields = match.groups()
        if name in components:
            raise VerificationError(f"duplicate Application Services component pin: {name}")
        components.add(name)
        if re.search(r'\b(?:branch|tag)\s*=', fields):
            raise VerificationError(f"floating Application Services component pin: {name}")
        if len(re.findall(r'\bgit\s*=\s*"' + re.escape(OFFICIAL_SOURCE) + r'"', fields)) != 1:
            raise VerificationError(f"unofficial Application Services component source: {name}")
        revisions = re.findall(r'\brev\s*=\s*"([^"]+)"', fields)
        if revisions != [revision]:
            raise VerificationError(f"Application Services component {name} is not exactly pinned")
    if components != EXPECTED_COMPONENTS:
        raise VerificationError(
            "Application Services Cargo components changed without baseline review"
        )


def _verify_cargo_lock(root: Path, revision: str) -> None:
    path = root / "xanh-sync-core/Cargo.lock"
    contents = _read_bounded(path)
    expected = f'git+{OFFICIAL_SOURCE}?rev={revision}#{revision}'
    sources = []
    for line in contents.splitlines():
        if line.startswith('source = "git+') and OFFICIAL_SOURCE in line:
            match = re.fullmatch(r'source = "([^"]+)"', line)
            if match is None:
                raise VerificationError("malformed Application Services Cargo.lock source")
            sources.append(match.group(1))
    if not sources or any(source != expected for source in sources):
        raise VerificationError("Cargo.lock is not closed over the pinned Application Services revision")


def _verify_constants_and_notice(root: Path, version: str, revision: str) -> None:
    library = _read_bounded(root / "xanh-sync-core/src/lib.rs")
    expected_version = (
        f'pub const APPLICATION_SERVICES_VERSION: &str = "{version}";'
    )
    expected_revision = (
        f'pub const APPLICATION_SERVICES_REVISION: &str = "{revision}";'
    )
    if library.count(expected_version) != 1 or library.count(expected_revision) != 1:
        raise VerificationError("Rust Application Services identity constants are stale")

    notice = _read_bounded(root / "THIRD_PARTY_NOTICES.md")
    required = (
        f"## Mozilla Application Services {version}",
        f"Application Services {version} at revision\n`{revision}`",
        f"releases/tag/v{version}",
    )
    if any(value not in notice for value in required):
        raise VerificationError("Application Services third-party notice is stale")


def verify_project(root: Path, tag_list: str) -> StableRelease:
    root = root.resolve()
    latest = latest_stable_release(tag_list)
    lock = read_lock(root / LOCK_PATH)
    if lock["version"] != latest.text or lock["tag"] != latest.tag:
        raise VerificationError(
            f"Application Services pin {lock['tag']} is stale; latest stable is {latest.tag}"
        )
    if lock["revision"] != latest.revision:
        raise VerificationError(
            f"Application Services revision {lock['revision']} does not match "
            f"{latest.tag} revision {latest.revision}"
        )
    _verify_cargo_manifest(root, latest.revision)
    _verify_cargo_lock(root, latest.revision)
    _verify_constants_and_notice(root, latest.text, latest.revision)
    return latest


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
        raise VerificationError(
            f"cannot query official Application Services tags: {error}"
        ) from error
    if completed.returncode:
        detail = completed.stderr.strip() or f"git exited with {completed.returncode}"
        raise VerificationError(f"cannot query official Application Services tags: {detail}")
    return completed.stdout


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when Xanh's Application Services pin is not Mozilla's latest stable tag."
        )
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
            _read_bounded(arguments.tags_file, MAX_TAG_LIST_BYTES)
            if arguments.tags_file
            else fetch_official_tags()
        )
        release = verify_project(arguments.root, tag_list)
    except VerificationError as error:
        print(f"Application Services latest-stable verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"Verified latest stable Mozilla Application Services {release.text} "
        f"at {release.revision}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
