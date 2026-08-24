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


GOOGLE_MAVEN = "https://dl.google.com/dl/android/maven2"
MAVEN_CENTRAL = "https://repo1.maven.org/maven2"
MAX_METADATA_BYTES = 1024 * 1024
MAX_GRADLE_FILE_BYTES = 1024 * 1024
MAX_GRADLE_FILES = 128
IGNORED_PATH_PARTS = {".git", ".gradle", "build"}
STABLE_VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
DATE_VERSION_PATTERN = re.compile(r"^20[0-9]{6}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
KSP_PLUGIN_ID = "com.google.devtools.ksp"
EXTERNALLY_GOVERNED_COORDINATES = {
    ("androidx.webkit", "webkit"),
    ("org.wpewebkit.wpeview", "wpeview"),
    ("io.github.lamppkk.xanhbrowser", "xanh-sync-android"),
    ("org.mozilla.appservices", "fxaclient"),
    ("org.mozilla.appservices", "places"),
    ("org.mozilla.appservices", "syncmanager"),
    ("org.mozilla.appservices", "logins"),
    ("org.mozilla.appservices", "tabs"),
}


class VerificationError(RuntimeError):
    pass


class StableRelease(NamedTuple):
    version: tuple[int, ...]
    text: str


class ArtifactRequirement(NamedTuple):
    group: str
    name: str
    extensions: tuple[str, ...]


class DependencySpec(NamedTuple):
    key: str
    group: str
    artifact: str
    metadata_url: str
    checksums: tuple[ArtifactRequirement, ...]


def _standard_spec(
    key: str,
    group: str,
    artifact: str,
    extensions: tuple[str, ...],
    repository: str = GOOGLE_MAVEN,
) -> DependencySpec:
    path = f"{group.replace('.', '/')}/{artifact}/maven-metadata.xml"
    return DependencySpec(
        key,
        group,
        artifact,
        f"{repository}/{path}",
        (ArtifactRequirement(group, artifact, extensions),),
    )


UI_SPECS = (
    DependencySpec(
        "activity",
        "androidx.activity",
        "activity-ktx",
        f"{GOOGLE_MAVEN}/androidx/activity/activity-ktx/maven-metadata.xml",
        (ArtifactRequirement("androidx.activity", "activity-ktx", ("aar", "module")),),
    ),
    DependencySpec(
        "annotation",
        "androidx.annotation",
        "annotation",
        f"{GOOGLE_MAVEN}/androidx/annotation/annotation/maven-metadata.xml",
        (ArtifactRequirement("androidx.annotation", "annotation", ("module",)),),
    ),
    DependencySpec(
        "appcompat",
        "androidx.appcompat",
        "appcompat",
        f"{GOOGLE_MAVEN}/androidx/appcompat/appcompat/maven-metadata.xml",
        (ArtifactRequirement("androidx.appcompat", "appcompat", ("aar", "module")),),
    ),
    DependencySpec(
        "browser",
        "androidx.browser",
        "browser",
        f"{GOOGLE_MAVEN}/androidx/browser/browser/maven-metadata.xml",
        (ArtifactRequirement("androidx.browser", "browser", ("aar", "module")),),
    ),
    DependencySpec(
        "material",
        "com.google.android.material",
        "material",
        f"{GOOGLE_MAVEN}/com/google/android/material/material/maven-metadata.xml",
        (
            ArtifactRequirement(
                "com.google.android.material", "material", ("aar", "module")
            ),
        ),
    ),
)
OPTIONAL_SPECS = (
    _standard_spec(
        "feature_delivery",
        "com.google.android.play",
        "feature-delivery-ktx",
        ("aar", "pom"),
    ),
    _standard_spec("biometric", "androidx.biometric", "biometric", ("aar", "module")),
    _standard_spec("core", "androidx.core", "core-ktx", ("aar", "module")),
    _standard_spec(
        "lifecycle_runtime",
        "androidx.lifecycle",
        "lifecycle-runtime-ktx",
        ("module",),
    ),
    _standard_spec(
        "lifecycle_process",
        "androidx.lifecycle",
        "lifecycle-process",
        ("aar", "module"),
    ),
    _standard_spec(
        "recyclerview", "androidx.recyclerview", "recyclerview", ("aar", "module")
    ),
    _standard_spec("room_runtime", "androidx.room", "room-runtime", ("module",)),
    _standard_spec("room_ktx", "androidx.room", "room-ktx", ("aar", "module")),
    _standard_spec(
        "room_compiler", "androidx.room", "room-compiler", ("jar", "module")
    ),
    _standard_spec("room_testing", "androidx.room", "room-testing", ("module",)),
    _standard_spec(
        "work", "androidx.work", "work-runtime-ktx", ("aar", "module")
    ),
    _standard_spec(
        "androidx_test_junit", "androidx.test.ext", "junit", ("aar", "pom")
    ),
    _standard_spec(
        "espresso", "androidx.test.espresso", "espresso-core", ("aar", "pom")
    ),
    _standard_spec("test_runner", "androidx.test", "runner", ("aar", "pom")),
    _standard_spec("junit4", "junit", "junit", ("jar", "pom"), MAVEN_CENTRAL),
    _standard_spec("json", "org.json", "json", ("jar", "pom"), MAVEN_CENTRAL),
)
KSP_SPEC = DependencySpec(
    "ksp",
    "com.google.devtools.ksp",
    "symbol-processing-gradle-plugin",
    f"{MAVEN_CENTRAL}/com/google/devtools/ksp/"
    "symbol-processing-gradle-plugin/maven-metadata.xml",
    (
        ArtifactRequirement(
            "com.google.devtools.ksp",
            "com.google.devtools.ksp.gradle.plugin",
            ("pom",),
        ),
        ArtifactRequirement(
            "com.google.devtools.ksp",
            "symbol-processing-gradle-plugin",
            ("jar", "module"),
        ),
    ),
)
SPECS_BY_KEY = {
    spec.key: spec for spec in (*UI_SPECS, *OPTIONAL_SPECS, KSP_SPEC)
}


def _single_child_text(parent: ET.Element, name: str) -> str:
    children = parent.findall(name)
    if len(children) != 1 or children[0].text is None or not children[0].text.strip():
        raise VerificationError(f"metadata must contain exactly one non-empty {name}")
    return children[0].text.strip()


def _stable_version(value: str, spec: DependencySpec) -> tuple[int, ...] | None:
    if spec.key == "json":
        return (int(value),) if DATE_VERSION_PATTERN.fullmatch(value) else None
    match = STABLE_VERSION_PATTERN.fullmatch(value)
    return tuple(int(part) for part in match.groups()) if match else None


def latest_stable_release(metadata: bytes, spec: DependencySpec) -> StableRelease:
    if len(metadata) > MAX_METADATA_BYTES:
        raise VerificationError(f"{spec.key} metadata exceeds the 1 MiB safety limit")
    try:
        text = metadata.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{spec.key} metadata is not valid UTF-8") from error
    upper = text.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        raise VerificationError("DTD and entity declarations are forbidden")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise VerificationError(f"{spec.key} metadata is malformed: {error}") from error
    if root.tag != "metadata":
        raise VerificationError(f"{spec.key} metadata has an unexpected root element")
    if _single_child_text(root, "groupId") != spec.group:
        raise VerificationError(f"{spec.key} metadata has the wrong groupId")
    if _single_child_text(root, "artifactId") != spec.artifact:
        raise VerificationError(f"{spec.key} metadata has the wrong artifactId")
    versioning = root.findall("versioning")
    if len(versioning) != 1:
        raise VerificationError(f"{spec.key} metadata must contain one versioning element")
    versions = versioning[0].findall("versions")
    if len(versions) != 1:
        raise VerificationError(f"{spec.key} metadata must contain one versions element")

    stable: dict[tuple[int, ...], str] = {}
    seen: set[str] = set()
    for node in versions[0].findall("version"):
        if node.attrib or len(node):
            raise VerificationError(f"{spec.key} metadata contains a structured version")
        value = (node.text or "").strip()
        if not value or value in seen:
            raise VerificationError(
                f"{spec.key} metadata contains an empty or duplicate version"
            )
        seen.add(value)
        parsed = _stable_version(value, spec)
        if parsed is None:
            continue
        stable[parsed] = value
    if not stable:
        raise VerificationError(f"{spec.key} metadata contains no stable release")
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


def _active_gradle_text(contents: str) -> str:
    without_blocks = re.sub(r"/\*.*?\*/", "", contents, flags=re.DOTALL)
    return "\n".join(
        line for line in without_blocks.splitlines() if not line.lstrip().startswith("//")
    )


def _gradle_sources(root: Path) -> list[tuple[Path, str]]:
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
    return [
        (path.relative_to(root), _active_gradle_text(_read_bounded(path, MAX_GRADLE_FILE_BYTES)))
        for path in files
    ]


def project_dependency_pins(root: Path) -> dict[str, list[tuple[Path, str]]]:
    sources = _gradle_sources(root)
    pins: dict[str, list[tuple[Path, str]]] = {}
    for spec in UI_SPECS:
        pattern = re.compile(
            rf"{re.escape(spec.group)}:{re.escape(spec.artifact)}:([^\s\"'`)]+)"
        )
        matches = [
            (path, match.group(1))
            for path, contents in sources
            for match in pattern.finditer(contents)
        ]
        if not matches:
            raise VerificationError(
                f"project contains no {spec.group}:{spec.artifact} dependency pin"
            )
        pins[spec.key] = matches

    for spec in OPTIONAL_SPECS:
        pattern = re.compile(
            rf"{re.escape(spec.group)}:{re.escape(spec.artifact)}:([^\s\"'`)]+)"
        )
        matches = [
            (path, match.group(1))
            for path, contents in sources
            for match in pattern.finditer(contents)
        ]
        if matches:
            pins[spec.key] = matches

    if any(KSP_PLUGIN_ID in contents for _, contents in sources):
        ksp_pattern = re.compile(
            r"\bid\s*(?:\(\s*)?['\"]com\.google\.devtools\.ksp['\"]\s*\)?"
            r"\s*version\s*(?:\(\s*)?['\"]([^'\"]+)"
        )
        matches = [
            (path, match.group(1))
            for path, contents in sources
            for match in ksp_pattern.finditer(contents)
        ]
        if not matches:
            raise VerificationError("KSP is applied but has no explicit root plugin version")
        pins[KSP_SPEC.key] = matches

    tracked_coordinates = {
        (spec.group, spec.artifact) for spec in (*UI_SPECS, *OPTIONAL_SPECS)
    }
    coordinate_pattern = re.compile(
        r"\b([A-Za-z0-9_.-]+):([A-Za-z0-9_.-]+):([^\s\"'`)]+)"
    )
    for path, contents in sources:
        for match in coordinate_pattern.finditer(contents):
            coordinate = (match.group(1), match.group(2))
            if (
                coordinate not in tracked_coordinates
                and coordinate not in EXTERNALLY_GOVERNED_COORDINATES
            ):
                raise VerificationError(
                    f"{path} contains an untracked direct dependency: "
                    f"{coordinate[0]}:{coordinate[1]}"
                )

    for key, matches in pins.items():
        spec = SPECS_BY_KEY[key]
        for path, version in matches:
            if _stable_version(version, spec) is None:
                raise VerificationError(
                    f"{path} uses a non-stable or dynamic {key} pin: {version}"
                )
    return pins


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def verify_gradle_checksums(
    path: Path, releases: dict[str, StableRelease], required_keys: set[str]
) -> None:
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

    for key in sorted(required_keys):
        spec = SPECS_BY_KEY[key]
        version = releases[key].text
        for requirement in spec.checksums:
            components = [
                node
                for node in root.iter()
                if _local_name(node.tag) == "component"
                and node.attrib.get("group") == requirement.group
                and node.attrib.get("name") == requirement.name
                and node.attrib.get("version") == version
            ]
            if len(components) != 1:
                raise VerificationError(
                    "Gradle verification metadata must contain exactly one "
                    f"{requirement.group}:{requirement.name}:{version} component"
                )
            for extension in requirement.extensions:
                artifact_name = f"{requirement.name}-{version}.{extension}"
                artifacts = [
                    child
                    for child in components[0]
                    if _local_name(child.tag) == "artifact"
                    and child.attrib.get("name") == artifact_name
                ]
                if len(artifacts) != 1:
                    raise VerificationError(
                        f"Gradle verification metadata must contain exactly one {artifact_name}"
                    )
                checksums = [
                    child.attrib.get("value", "")
                    for child in artifacts[0]
                    if _local_name(child.tag) == "sha256"
                ]
                if len(checksums) != 1 or SHA256_PATTERN.fullmatch(checksums[0]) is None:
                    raise VerificationError(
                        f"Gradle verification metadata has an invalid hash for {artifact_name}"
                    )


def verify_project(
    root: Path, metadata_by_key: dict[str, bytes]
) -> dict[str, StableRelease]:
    root = root.resolve()
    pins = project_dependency_pins(root)
    required_keys = set(pins)
    if set(metadata_by_key) != required_keys:
        raise VerificationError(
            "metadata keys must exactly match project dependencies: "
            + ", ".join(sorted(required_keys))
        )
    releases = {
        key: latest_stable_release(metadata_by_key[key], SPECS_BY_KEY[key])
        for key in sorted(required_keys)
    }
    stale = [
        (key, path, version, releases[key].text)
        for key, matches in pins.items()
        for path, version in matches
        if version != releases[key].text
    ]
    if stale:
        detail = ", ".join(
            f"{path}:{key}={version} (latest {latest})"
            for key, path, version, latest in stale
        )
        raise VerificationError(f"Android UI/tooling pins are stale: {detail}")
    verification_metadata = root / "gradle/verification-metadata.xml"
    if verification_metadata.exists() or verification_metadata.is_symlink():
        verify_gradle_checksums(verification_metadata, releases, required_keys)
    return releases


def _validate_metadata_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise VerificationError("dependency metadata URL must be credential-free HTTPS")


def fetch_official_metadata(spec: DependencySpec) -> bytes:
    _validate_metadata_url(spec.metadata_url)
    parsed = urlparse(spec.metadata_url)
    request = urllib.request.Request(
        spec.metadata_url,
        headers={"User-Agent": "XanhBrowser-Android-UI-Verifier/1.0"},
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
                raise VerificationError(f"{spec.key} metadata redirected outside its origin")
            length = response.headers.get("Content-Length")
            if length is not None and int(length) > MAX_METADATA_BYTES:
                raise VerificationError(f"{spec.key} metadata exceeds the 1 MiB safety limit")
            contents = response.read(MAX_METADATA_BYTES + 1)
    except (OSError, ValueError, urllib.error.URLError) as error:
        raise VerificationError(f"cannot query official {spec.key} metadata: {error}") from error
    if len(contents) > MAX_METADATA_BYTES:
        raise VerificationError(f"{spec.key} metadata exceeds the 1 MiB safety limit")
    return contents


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when Xanh does not use the latest stable direct Android dependencies."
        )
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root",
    )
    parser.add_argument(
        "--metadata-directory",
        type=Path,
        help="read <dependency>.xml fixtures instead of querying official repositories",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        root = arguments.root.resolve()
        required_keys = set(project_dependency_pins(root))
        if arguments.metadata_directory:
            metadata_by_key = {
                key: _read_bounded_bytes(
                    arguments.metadata_directory / f"{key}.xml", MAX_METADATA_BYTES
                )
                for key in sorted(required_keys)
            }
        else:
            metadata_by_key = {
                key: fetch_official_metadata(SPECS_BY_KEY[key])
                for key in sorted(required_keys)
            }
        releases = verify_project(root, metadata_by_key)
    except (OSError, VerificationError) as error:
        print(
            f"Android direct-dependency latest-stable verification failed: {error}",
            file=sys.stderr,
        )
        return 1
    summary = ", ".join(f"{key} {releases[key].text}" for key in sorted(releases))
    print(f"Verified latest stable direct Android dependencies: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
