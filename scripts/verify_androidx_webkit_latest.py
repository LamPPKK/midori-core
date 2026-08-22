#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple
from urllib.parse import urlparse


OFFICIAL_METADATA_URL = (
    "https://dl.google.com/dl/android/maven2/"
    "androidx/webkit/webkit/maven-metadata.xml"
)
MAX_METADATA_BYTES = 1024 * 1024
MAX_GRADLE_FILE_BYTES = 1024 * 1024
MAX_GRADLE_FILES = 128
IGNORED_PATH_PARTS = {".git", ".gradle", "build"}
STABLE_VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
DEPENDENCY_PATTERN = re.compile(r"androidx\.webkit:webkit:([^\s\"'`)]+)")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class VerificationError(RuntimeError):
    pass


class StableRelease(NamedTuple):
    version: tuple[int, int, int]
    text: str


def _single_child_text(parent: ET.Element, name: str) -> str:
    children = parent.findall(name)
    if len(children) != 1 or children[0].text is None or not children[0].text.strip():
        raise VerificationError(f"metadata must contain exactly one non-empty {name}")
    return children[0].text.strip()


def latest_stable_release(metadata: bytes) -> StableRelease:
    if len(metadata) > MAX_METADATA_BYTES:
        raise VerificationError("Google Maven metadata exceeds the 1 MiB safety limit")
    try:
        text = metadata.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError("Google Maven metadata is not valid UTF-8") from error
    upper = text.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        raise VerificationError("DTD and entity declarations are forbidden")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise VerificationError(f"Google Maven metadata is malformed: {error}") from error
    if root.tag != "metadata":
        raise VerificationError("Google Maven metadata has an unexpected root element")
    if _single_child_text(root, "groupId") != "androidx.webkit":
        raise VerificationError("Google Maven metadata has the wrong groupId")
    if _single_child_text(root, "artifactId") != "webkit":
        raise VerificationError("Google Maven metadata has the wrong artifactId")
    versioning = root.findall("versioning")
    if len(versioning) != 1:
        raise VerificationError("Google Maven metadata must contain one versioning element")
    versions_elements = versioning[0].findall("versions")
    if len(versions_elements) != 1:
        raise VerificationError("Google Maven metadata must contain one versions element")

    stable: dict[tuple[int, int, int], str] = {}
    seen: set[str] = set()
    for node in versions_elements[0].findall("version"):
        if node.attrib or len(node):
            raise VerificationError("Google Maven metadata contains a structured version")
        value = (node.text or "").strip()
        if not value or value in seen:
            raise VerificationError("Google Maven metadata contains an empty or duplicate version")
        seen.add(value)
        match = STABLE_VERSION_PATTERN.fullmatch(value)
        if match is None:
            continue
        parsed = tuple(int(part) for part in match.groups())
        stable[parsed] = value
    if not stable:
        raise VerificationError("Google Maven metadata contains no stable AndroidX WebKit release")
    version = max(stable)
    return StableRelease(version, stable[version])


def _read_bounded_bytes(path: Path, limit: int) -> bytes:
    try:
        if path.is_symlink() or not path.is_file():
            raise VerificationError(f"{path} must be a regular file")
        with path.open("rb") as stream:
            contents = stream.read(limit + 1)
        if len(contents) > limit:
            raise VerificationError(f"{path} exceeds the {limit}-byte safety limit")
        return contents
    except OSError as error:
        raise VerificationError(f"cannot read {path}: {error}") from error


def _read_bounded(path: Path, limit: int) -> str:
    try:
        return _read_bounded_bytes(path, limit).decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{path} is not valid UTF-8") from error


def project_webkit_pins(root: Path) -> list[tuple[Path, str]]:
    files: list[Path] = []
    for directory, names, filenames in os.walk(root, followlinks=False):
        current = Path(directory)
        names[:] = sorted(
            name
            for name in names
            if name not in IGNORED_PATH_PARTS and not (current / name).is_symlink()
        )
        for filename in filenames:
            if filename in {"build.gradle", "build.gradle.kts"}:
                files.append(current / filename)
                if len(files) > MAX_GRADLE_FILES:
                    raise VerificationError("project contains too many Gradle build files")
    files.sort()
    pins: list[tuple[Path, str]] = []
    for path in files:
        contents = _read_bounded(path, MAX_GRADLE_FILE_BYTES)
        for match in DEPENDENCY_PATTERN.finditer(contents):
            value = match.group(1)
            if STABLE_VERSION_PATTERN.fullmatch(value) is None:
                raise VerificationError(f"{path} uses a non-stable or dynamic WebKit pin: {value}")
            pins.append((path.relative_to(root), value))
    if not pins:
        raise VerificationError("project contains no androidx.webkit:webkit dependency pin")
    return pins


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def verify_gradle_checksums(path: Path, version: str) -> None:
    contents = _read_bounded(path, MAX_METADATA_BYTES)
    upper = contents.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        raise VerificationError("Gradle verification metadata cannot contain DTD/entities")
    try:
        root = ET.fromstring(contents)
    except ET.ParseError as error:
        raise VerificationError(f"Gradle verification metadata is malformed: {error}") from error
    if _local_name(root.tag) != "verification-metadata":
        raise VerificationError("Gradle verification metadata has an unexpected root")
    components = [
        node
        for node in root.iter()
        if _local_name(node.tag) == "component"
        and node.attrib.get("group") == "androidx.webkit"
        and node.attrib.get("name") == "webkit"
    ]
    if len(components) != 1 or components[0].attrib.get("version") != version:
        raise VerificationError("Gradle verification metadata must pin exactly the latest WebKit")
    for name in (f"webkit-{version}.aar", f"webkit-{version}.module"):
        artifacts = [
            child
            for child in components[0]
            if _local_name(child.tag) == "artifact" and child.attrib.get("name") == name
        ]
        if len(artifacts) != 1:
            raise VerificationError(
                f"Gradle verification metadata must contain exactly one {name}"
            )
        checksums = [
            child.attrib.get("value", "")
            for child in artifacts[0]
            if _local_name(child.tag) == "sha256"
        ]
        if len(checksums) != 1 or SHA256_PATTERN.fullmatch(checksums[0]) is None:
            raise VerificationError(f"Gradle verification metadata has an invalid hash for {name}")


def verify_project(root: Path, metadata: bytes) -> StableRelease:
    root = root.resolve()
    latest = latest_stable_release(metadata)
    pins = project_webkit_pins(root)
    stale = [(path, version) for path, version in pins if version != latest.text]
    if stale:
        detail = ", ".join(f"{path}={version}" for path, version in stale)
        raise VerificationError(
            f"AndroidX WebKit pins are stale ({detail}); latest stable is {latest.text}"
        )
    verification_metadata = root / "gradle/verification-metadata.xml"
    if verification_metadata.exists() or verification_metadata.is_symlink():
        verify_gradle_checksums(verification_metadata, latest.text)
    return latest


def fetch_official_metadata(url: str) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise VerificationError("AndroidX metadata URL must be credential-free HTTPS")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "XanhBrowser-AndroidX-WebKit-Verifier/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            final = urlparse(response.geturl())
            if (
                final.scheme != "https"
                or not final.netloc
                or final.username
                or final.password
                or final.hostname != parsed.hostname
                or final.port != parsed.port
            ):
                raise VerificationError("AndroidX metadata redirected outside HTTPS")
            length = response.headers.get("Content-Length")
            if length is not None and int(length) > MAX_METADATA_BYTES:
                raise VerificationError("Google Maven metadata exceeds the 1 MiB safety limit")
            contents = response.read(MAX_METADATA_BYTES + 1)
    except (OSError, ValueError, urllib.error.URLError) as error:
        raise VerificationError(f"cannot query official AndroidX metadata: {error}") from error
    if len(contents) > MAX_METADATA_BYTES:
        raise VerificationError("Google Maven metadata exceeds the 1 MiB safety limit")
    return contents


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail when Xanh does not use the latest stable AndroidX WebKit release."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root",
    )
    parser.add_argument(
        "--metadata-file",
        type=Path,
        help="read Google Maven metadata from a fixture instead of the network",
    )
    parser.add_argument(
        "--metadata-url",
        default=OFFICIAL_METADATA_URL,
        help="metadata endpoint; defaults to the official Google Maven repository",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        metadata = (
            _read_bounded_bytes(arguments.metadata_file, MAX_METADATA_BYTES)
            if arguments.metadata_file
            else fetch_official_metadata(arguments.metadata_url)
        )
        release = verify_project(arguments.root, metadata)
    except (OSError, VerificationError) as error:
        print(f"AndroidX WebKit latest-stable verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified latest stable AndroidX WebKit {release.text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
