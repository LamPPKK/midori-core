#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple
from urllib.parse import urlparse


AGP_METADATA_URL = (
    "https://dl.google.com/dl/android/maven2/"
    "com/android/tools/build/gradle/maven-metadata.xml"
)
GRADLE_CURRENT_URL = "https://services.gradle.org/versions/current"
MAX_REMOTE_BYTES = 1024 * 1024
MAX_PROJECT_FILE_BYTES = 1024 * 1024
MAX_WRAPPER_JAR_BYTES = 2 * 1024 * 1024
STABLE_VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ANDROID_PLUGIN_PATTERN = re.compile(
    r"id\s+['\"]com\.android\.(application|library|dynamic-feature)['\"]"
    r"\s+version\s+['\"]([^'\"]+)['\"]"
)


class VerificationError(RuntimeError):
    pass


class StableRelease(NamedTuple):
    version: tuple[int, int, int]
    text: str


class GradleRelease(NamedTuple):
    version: tuple[int, int, int]
    text: str
    distribution_url: str
    distribution_checksum: str
    wrapper_checksum: str


def _single_child_text(parent: ET.Element, name: str) -> str:
    children = parent.findall(name)
    if len(children) != 1 or children[0].text is None or not children[0].text.strip():
        raise VerificationError(f"metadata must contain exactly one non-empty {name}")
    return children[0].text.strip()


def latest_agp_release(metadata: bytes) -> StableRelease:
    if len(metadata) > MAX_REMOTE_BYTES:
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
    if _single_child_text(root, "groupId") != "com.android.tools.build":
        raise VerificationError("Google Maven metadata has the wrong groupId")
    if _single_child_text(root, "artifactId") != "gradle":
        raise VerificationError("Google Maven metadata has the wrong artifactId")
    versioning = root.findall("versioning")
    if len(versioning) != 1:
        raise VerificationError("Google Maven metadata must contain one versioning element")
    containers = versioning[0].findall("versions")
    if len(containers) != 1:
        raise VerificationError("Google Maven metadata must contain one versions element")

    stable: dict[tuple[int, int, int], str] = {}
    seen: set[str] = set()
    for node in containers[0].findall("version"):
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
        raise VerificationError("Google Maven metadata contains no stable AGP release")
    version = max(stable)
    return StableRelease(version, stable[version])


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f"Gradle metadata contains duplicate key: {key}")
        result[key] = value
    return result


def current_gradle_release(metadata: bytes) -> GradleRelease:
    if len(metadata) > MAX_REMOTE_BYTES:
        raise VerificationError("Gradle metadata exceeds the 1 MiB safety limit")
    try:
        text = metadata.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError("Gradle metadata is not valid UTF-8") from error
    try:
        document = json.loads(text, object_pairs_hook=_unique_json_object)
    except (json.JSONDecodeError, VerificationError) as error:
        raise VerificationError(f"Gradle metadata is malformed: {error}") from error
    if not isinstance(document, dict):
        raise VerificationError("Gradle metadata must be a JSON object")
    version_text = document.get("version")
    if not isinstance(version_text, str):
        raise VerificationError("Gradle metadata has no version")
    match = STABLE_VERSION_PATTERN.fullmatch(version_text)
    if match is None:
        raise VerificationError("Gradle current release is not a stable three-part version")
    for name in ("current", "released", "final"):
        if document.get(name) is not True:
            raise VerificationError(f"Gradle metadata must mark {name}=true")
    for name in ("snapshot", "nightly", "activeRc", "broken"):
        if document.get(name) is not False:
            raise VerificationError(f"Gradle metadata must mark {name}=false")
    if document.get("publicationSlot") != version_text:
        raise VerificationError("Gradle publication slot does not match the current version")

    distribution_url = f"https://services.gradle.org/distributions/gradle-{version_text}-bin.zip"
    checksum_url = f"{distribution_url}.sha256"
    wrapper_checksum_url = (
        f"https://services.gradle.org/distributions/gradle-{version_text}-wrapper.jar.sha256"
    )
    if document.get("downloadUrl") != distribution_url:
        raise VerificationError("Gradle download URL is not the exact official binary distribution")
    if document.get("checksumUrl") != checksum_url:
        raise VerificationError("Gradle checksum URL is not the exact official endpoint")
    if document.get("wrapperChecksumUrl") != wrapper_checksum_url:
        raise VerificationError("Gradle wrapper checksum URL is not the exact official endpoint")
    checksum = document.get("checksum")
    wrapper_checksum = document.get("wrapperChecksum")
    if not isinstance(checksum, str) or SHA256_PATTERN.fullmatch(checksum) is None:
        raise VerificationError("Gradle distribution checksum is invalid")
    if not isinstance(wrapper_checksum, str) or SHA256_PATTERN.fullmatch(wrapper_checksum) is None:
        raise VerificationError("Gradle wrapper checksum is invalid")
    return GradleRelease(
        tuple(int(part) for part in match.groups()),
        version_text,
        distribution_url,
        checksum,
        wrapper_checksum,
    )


def _read_bounded_bytes(path: Path, limit: int) -> bytes:
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


def _read_bounded(path: Path, limit: int) -> str:
    try:
        return _read_bounded_bytes(path, limit).decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{path} is not valid UTF-8") from error


def _properties(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in _read_bounded(path, MAX_PROJECT_FILE_BYTES).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            raise VerificationError(f"{path} contains a malformed property")
        key, value = stripped.split("=", 1)
        if not key or key in values:
            raise VerificationError(f"{path} contains an empty or duplicate property")
        values[key] = value
    return values


def verify_project(root: Path, agp_metadata: bytes, gradle_metadata: bytes) -> tuple[StableRelease, GradleRelease]:
    root = root.resolve()
    agp = latest_agp_release(agp_metadata)
    gradle = current_gradle_release(gradle_metadata)

    build_file = root / "build.gradle"
    pins = ANDROID_PLUGIN_PATTERN.findall(_read_bounded(build_file, MAX_PROJECT_FILE_BYTES))
    kinds = [kind for kind, _ in pins]
    if kinds.count("application") != 1 or kinds.count("library") != 1 or len(kinds) != len(set(kinds)):
        raise VerificationError("root build.gradle must pin each Android plugin at most once")
    stale_plugins = [(kind, version) for kind, version in pins if version != agp.text]
    if stale_plugins:
        detail = ", ".join(f"{kind}={version}" for kind, version in stale_plugins)
        raise VerificationError(f"Android Gradle Plugin pins are stale ({detail}); latest is {agp.text}")

    wrapper_properties = _properties(root / "gradle/wrapper/gradle-wrapper.properties")
    expected_url = gradle.distribution_url.replace("https:", "https\\:")
    if wrapper_properties.get("distributionUrl") != expected_url:
        raise VerificationError(f"Gradle wrapper must use exact latest distribution {gradle.text}")
    if wrapper_properties.get("distributionSha256Sum") != gradle.distribution_checksum:
        raise VerificationError("Gradle wrapper distribution checksum is stale or invalid")
    if wrapper_properties.get("validateDistributionUrl") != "true":
        raise VerificationError("Gradle wrapper must validate its distribution URL")

    wrapper_jar = _read_bounded_bytes(
        root / "gradle/wrapper/gradle-wrapper.jar",
        MAX_WRAPPER_JAR_BYTES,
    )
    if hashlib.sha256(wrapper_jar).hexdigest() != gradle.wrapper_checksum:
        raise VerificationError("Gradle wrapper JAR does not match the official current checksum")
    gradlew = root / "gradlew"
    if gradlew.is_symlink() or not gradlew.is_file() or gradlew.stat().st_mode & 0o111 == 0:
        raise VerificationError("gradlew must be a regular executable file")
    if not (root / "gradlew.bat").is_file() or (root / "gradlew.bat").is_symlink():
        raise VerificationError("gradlew.bat must be a regular file")
    return agp, gradle


def fetch_official_metadata(url: str, label: str) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise VerificationError(f"{label} URL must be credential-free HTTPS")
    request = urllib.request.Request(url, headers={"User-Agent": "XanhBrowser-Toolchain-Verifier/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            final = urlparse(response.geturl())
            if (
                final.scheme != "https"
                or final.hostname != parsed.hostname
                or final.port != parsed.port
                or final.username
                or final.password
            ):
                raise VerificationError(f"{label} metadata redirected outside its official origin")
            length = response.headers.get("Content-Length")
            if length is not None and int(length) > MAX_REMOTE_BYTES:
                raise VerificationError(f"{label} metadata exceeds the 1 MiB safety limit")
            contents = response.read(MAX_REMOTE_BYTES + 1)
    except (OSError, ValueError, urllib.error.URLError) as error:
        raise VerificationError(f"cannot query official {label} metadata: {error}") from error
    if len(contents) > MAX_REMOTE_BYTES:
        raise VerificationError(f"{label} metadata exceeds the 1 MiB safety limit")
    return contents


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail when Xanh does not use the latest stable AGP and Gradle releases."
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--agp-metadata-file", type=Path)
    parser.add_argument("--gradle-metadata-file", type=Path)
    parser.add_argument("--agp-metadata-url", default=AGP_METADATA_URL)
    parser.add_argument("--gradle-metadata-url", default=GRADLE_CURRENT_URL)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        agp_metadata = (
            _read_bounded_bytes(arguments.agp_metadata_file, MAX_REMOTE_BYTES)
            if arguments.agp_metadata_file
            else fetch_official_metadata(arguments.agp_metadata_url, "AGP")
        )
        gradle_metadata = (
            _read_bounded_bytes(arguments.gradle_metadata_file, MAX_REMOTE_BYTES)
            if arguments.gradle_metadata_file
            else fetch_official_metadata(arguments.gradle_metadata_url, "Gradle")
        )
        agp, gradle = verify_project(arguments.root, agp_metadata, gradle_metadata)
    except (OSError, VerificationError) as error:
        print(f"Android toolchain latest-stable verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified latest stable Android Gradle Plugin {agp.text} and Gradle {gradle.text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
