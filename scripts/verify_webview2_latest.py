#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple
from urllib.parse import urlparse


OFFICIAL_INDEX_URL = (
    "https://api.nuget.org/v3-flatcontainer/"
    "microsoft.web.webview2/index.json"
)
PACKAGE_ID = "Microsoft.Web.WebView2"
RUNTIME_POLICY_PATH = Path(
    "platform/windows/src/XanhBrowser.Core/WebView2RuntimePolicy.cs"
)
MAX_INDEX_BYTES = 1024 * 1024
MAX_PROJECT_BYTES = 1024 * 1024
MAX_PROJECT_FILES = 128
MAX_VERSIONS = 2048
IGNORED_PATH_PARTS = {".git", ".gradle", "bin", "build", "obj"}
STABLE_VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:\.(0|[1-9][0-9]*))?$"
)
RUNTIME_POLICY_PATTERN = re.compile(
    rb'^\s*public const string MinimumVersion = "'
    rb'((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.'
    rb'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))";\s*$',
    re.MULTILINE,
)


class VerificationError(RuntimeError):
    pass


class StableRelease(NamedTuple):
    version: tuple[int, int, int, int]
    text: str


def _object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f"NuGet index contains duplicate key: {key}")
        result[key] = value
    return result


def latest_stable_release(contents: bytes) -> StableRelease:
    if len(contents) > MAX_INDEX_BYTES:
        raise VerificationError("NuGet index exceeds the 1 MiB safety limit")
    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError("NuGet index is not valid UTF-8") from error
    try:
        root = json.loads(text, object_pairs_hook=_object_without_duplicate_keys)
    except (ValueError, VerificationError) as error:
        raise VerificationError(f"NuGet index is malformed: {error}") from error
    if not isinstance(root, dict) or set(root) != {"versions"}:
        raise VerificationError("NuGet index must contain only the versions array")
    versions = root["versions"]
    if not isinstance(versions, list) or not versions or len(versions) > MAX_VERSIONS:
        raise VerificationError("NuGet index has an invalid versions array")

    stable: dict[tuple[int, int, int, int], str] = {}
    seen: set[str] = set()
    for value in versions:
        if not isinstance(value, str) or not value or len(value) > 64 or value in seen:
            raise VerificationError("NuGet index contains an invalid or duplicate version")
        seen.add(value)
        match = STABLE_VERSION_PATTERN.fullmatch(value)
        if match is None:
            continue
        parts = tuple(int(part) if part is not None else 0 for part in match.groups())
        if parts in stable:
            raise VerificationError("NuGet index contains duplicate normalized versions")
        stable[parts] = value
    if not stable:
        raise VerificationError("NuGet index contains no stable WebView2 SDK release")
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


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _project_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for directory, names, filenames in os.walk(root, followlinks=False):
        current = Path(directory)
        names[:] = sorted(
            name
            for name in names
            if name not in IGNORED_PATH_PARTS and not (current / name).is_symlink()
        )
        for filename in filenames:
            if filename.endswith(".csproj") or filename == "Directory.Packages.props":
                files.append(current / filename)
                if len(files) > MAX_PROJECT_FILES:
                    raise VerificationError("project contains too many MSBuild project files")
    return sorted(files)


def _version_for_package_node(path: Path, node: ET.Element) -> str | None:
    attribute = node.attrib.get("Version")
    children = [child for child in node if _local_name(child.tag) == "Version"]
    if attribute is not None and children:
        raise VerificationError(f"{path} declares WebView2 Version twice")
    if len(children) > 1:
        raise VerificationError(f"{path} declares multiple WebView2 Version elements")
    if attribute is not None:
        return attribute.strip()
    if children:
        return (children[0].text or "").strip()
    return None


def project_webview2_pins(root: Path) -> list[tuple[Path, str]]:
    pins: list[tuple[Path, str]] = []
    references = 0
    for path in _project_files(root):
        contents = _read_bounded_bytes(path, MAX_PROJECT_BYTES)
        upper = contents.upper()
        if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
            raise VerificationError(f"{path} cannot contain DTD/entity declarations")
        try:
            project = ET.fromstring(contents)
        except ET.ParseError as error:
            raise VerificationError(f"{path} is malformed XML: {error}") from error
        if _local_name(project.tag) != "Project":
            raise VerificationError(f"{path} has an unexpected MSBuild root element")
        for node in project.iter():
            if _local_name(node.tag) not in {"PackageReference", "PackageVersion"}:
                continue
            identity = node.attrib.get("Include") or node.attrib.get("Update") or ""
            if identity.casefold() != PACKAGE_ID.casefold():
                continue
            references += 1
            version = _version_for_package_node(path, node)
            if version is None:
                continue
            if STABLE_VERSION_PATTERN.fullmatch(version) is None:
                raise VerificationError(
                    f"{path} uses a non-stable or dynamic WebView2 pin: {version or '<empty>'}"
                )
            pins.append((path.relative_to(root), version))
    if references == 0:
        raise VerificationError(f"project contains no {PACKAGE_ID} reference")
    if not pins:
        raise VerificationError(f"project contains no explicit {PACKAGE_ID} version pin")
    return pins


def verify_runtime_policy(root: Path, latest: StableRelease) -> None:
    path = root / RUNTIME_POLICY_PATH
    contents = _read_bounded_bytes(path, MAX_PROJECT_BYTES)
    matches = RUNTIME_POLICY_PATTERN.findall(contents)
    if len(matches) != 1:
        raise VerificationError(
            f"{RUNTIME_POLICY_PATH} must declare exactly one numeric MinimumVersion"
        )
    text = matches[0].decode("ascii")
    components = tuple(int(part) for part in text.split("."))
    if components[0] < 86 or components[1:] != latest.version[1:]:
        raise VerificationError(
            f"WebView2 Runtime floor {text} does not match SDK {latest.text}; "
            "verify the required Runtime major in Microsoft's release notes"
        )


def verify_project(root: Path, contents: bytes) -> StableRelease:
    root = root.resolve()
    latest = latest_stable_release(contents)
    stale = [
        (path, version)
        for path, version in project_webview2_pins(root)
        if version != latest.text
    ]
    if stale:
        detail = ", ".join(f"{path}={version}" for path, version in stale)
        raise VerificationError(
            f"WebView2 SDK pins are stale ({detail}); latest stable is {latest.text}"
        )
    verify_runtime_policy(root, latest)
    return latest


def fetch_official_index(url: str) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise VerificationError("WebView2 index URL must be credential-free HTTPS")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "XanhBrowser-WebView2-Verifier/1.0"},
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
                raise VerificationError("WebView2 index redirected outside official HTTPS")
            length = response.headers.get("Content-Length")
            if length is not None and int(length) > MAX_INDEX_BYTES:
                raise VerificationError("NuGet index exceeds the 1 MiB safety limit")
            contents = response.read(MAX_INDEX_BYTES + 1)
    except (OSError, ValueError, urllib.error.URLError) as error:
        raise VerificationError(f"cannot query official WebView2 index: {error}") from error
    if len(contents) > MAX_INDEX_BYTES:
        raise VerificationError("NuGet index exceeds the 1 MiB safety limit")
    return contents


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail when Xanh does not use the latest stable WebView2 SDK."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root",
    )
    parser.add_argument(
        "--index-file",
        type=Path,
        help="read a NuGet index fixture instead of the network",
    )
    parser.add_argument(
        "--index-url",
        default=OFFICIAL_INDEX_URL,
        help="index endpoint; defaults to the official NuGet flat-container API",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        contents = (
            _read_bounded_bytes(arguments.index_file, MAX_INDEX_BYTES)
            if arguments.index_file
            else fetch_official_index(arguments.index_url)
        )
        release = verify_project(arguments.root, contents)
    except VerificationError as error:
        print(f"WebView2 latest-stable verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified latest stable Microsoft.Web.WebView2 {release.text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
