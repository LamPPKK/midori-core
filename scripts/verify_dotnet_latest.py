#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import NamedTuple
from urllib.parse import urlparse


DOTNET_INDEX_URL = (
    "https://builds.dotnet.microsoft.com/dotnet/"
    "release-metadata/releases-index.json"
)
MAX_REMOTE_BYTES = 1024 * 1024
MAX_PROJECT_FILE_BYTES = 1024 * 1024
CHANNEL_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
WORKFLOW_DOTNET_FIELD_PATTERN = re.compile(
    r"(?m)^[ \t]*dotnet-version[ \t]*:[^\r\n]*$"
)
WORKFLOW_DOTNET_VALUE_PATTERN = re.compile(
    r"(?m)^[ \t]*dotnet-version[ \t]*:[ \t]*(['\"])([^'\"\r\n]+)\1"
    r"[ \t]*(?:#[^\r\n]*)?$"
)
SETUP_DOTNET_STEP_PATTERN = re.compile(
    r"^(?P<indent>[ \t]*)-[ \t]+uses:[ \t]+actions/setup-dotnet@[^\s#]+"
    r"[ \t]*(?:#[^\r\n]*)?$"
)


class VerificationError(RuntimeError):
    pass


class DotNetRelease(NamedTuple):
    channel: tuple[int, int]
    channel_text: str
    runtime: str
    sdk: str


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f".NET metadata contains duplicate key: {key}")
        result[key] = value
    return result


def _strict_json(contents: bytes, label: str) -> object:
    if len(contents) > MAX_REMOTE_BYTES:
        raise VerificationError(f"{label} exceeds the 1 MiB safety limit")
    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{label} is not valid UTF-8") from error
    try:
        return json.loads(text, object_pairs_hook=_unique_json_object)
    except (json.JSONDecodeError, VerificationError) as error:
        raise VerificationError(f"{label} is malformed: {error}") from error


def _parse_three_part(value: object, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        raise VerificationError(f"{label} must be a stable three-part version")
    match = VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise VerificationError(f"{label} must be a stable three-part version")
    return tuple(int(part) for part in match.groups())


def latest_dotnet_release(metadata: bytes) -> DotNetRelease:
    document = _strict_json(metadata, ".NET releases index")
    if not isinstance(document, dict) or set(document) != {
        "$schema",
        "releases-index",
        "signature",
    }:
        raise VerificationError(".NET releases index has an unexpected root object")
    if document["$schema"] != "https://json.schemastore.org/dotnet-releases-index.json":
        raise VerificationError(".NET releases index has an unexpected schema")
    signature = document["signature"]
    if not isinstance(signature, dict) or set(signature) != {"expiration", "file"}:
        raise VerificationError(".NET releases index has invalid signature metadata")
    if not isinstance(signature["file"], str) or re.fullmatch(
        r"releases-index\.json\.[0-9]{14}\.p7s", signature["file"]
    ) is None:
        raise VerificationError(".NET releases index has an invalid signature filename")
    if not isinstance(signature["expiration"], str):
        raise VerificationError(".NET releases index has an invalid signature expiration")
    try:
        expiration = datetime.fromisoformat(signature["expiration"])
    except ValueError as error:
        raise VerificationError(
            ".NET releases index has an invalid signature expiration"
        ) from error
    if expiration.tzinfo is None or expiration <= datetime.now(timezone.utc):
        raise VerificationError(".NET releases index signature metadata is expired")
    entries = document["releases-index"]
    if not isinstance(entries, list):
        raise VerificationError(".NET releases index must contain an array")

    stable: dict[tuple[int, int], DotNetRelease] = {}
    seen_channels: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise VerificationError(".NET releases index contains a non-object entry")
        channel_text = entry.get("channel-version")
        if not isinstance(channel_text, str) or channel_text in seen_channels:
            raise VerificationError(".NET releases index has an invalid or duplicate channel")
        seen_channels.add(channel_text)
        channel_match = CHANNEL_PATTERN.fullmatch(channel_text)
        if channel_match is None:
            raise VerificationError(".NET releases index contains a malformed channel")
        if entry.get("support-phase") not in {"active", "maintenance"}:
            continue
        if entry.get("release-type") not in {"lts", "sts"}:
            raise VerificationError("supported .NET channel has an invalid release type")
        if entry.get("product") != ".NET" or not isinstance(entry.get("security"), bool):
            raise VerificationError("supported .NET channel has invalid product metadata")

        channel = tuple(int(part) for part in channel_match.groups())
        runtime = entry.get("latest-release")
        runtime_parts = _parse_three_part(runtime, "latest .NET runtime")
        if runtime_parts[:2] != channel or entry.get("latest-runtime") != runtime:
            raise VerificationError(".NET runtime metadata does not match its channel")
        sdk = entry.get("latest-sdk")
        sdk_parts = _parse_three_part(sdk, "latest .NET SDK")
        if sdk_parts[:2] != channel:
            raise VerificationError(".NET SDK metadata does not match its channel")
        expected_releases = (
            "https://builds.dotnet.microsoft.com/dotnet/"
            f"release-metadata/{channel_text}/releases.json"
        )
        expected_supported_os = (
            "https://builds.dotnet.microsoft.com/dotnet/"
            f"release-metadata/{channel_text}/supported-os.json"
        )
        if entry.get("releases.json") != expected_releases:
            raise VerificationError(".NET channel uses a non-official releases endpoint")
        if entry.get("supported-os.json") != expected_supported_os:
            raise VerificationError(".NET channel uses a non-official supported-OS endpoint")
        eol = entry.get("eol-date")
        if not isinstance(eol, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", eol) is None:
            raise VerificationError("supported .NET channel has no valid EOL date")
        stable[channel] = DotNetRelease(channel, channel_text, runtime, sdk)

    if not stable:
        raise VerificationError(".NET releases index contains no supported stable channel")
    return stable[max(stable)]


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


def _read_bounded(path: Path, limit: int = MAX_PROJECT_FILE_BYTES) -> str:
    try:
        return _read_bounded_bytes(path, limit).decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{path} is not valid UTF-8") from error


def _xml_local_name(name: str) -> str:
    return name.rsplit("}", 1)[-1]


def _project_xml(path: Path) -> ET.Element:
    try:
        root = ET.fromstring(_read_bounded(path))
    except ET.ParseError as error:
        raise VerificationError(f"{path} is malformed XML: {error}") from error
    if _xml_local_name(root.tag) != "Project":
        raise VerificationError(f"{path} has an unexpected root element")
    return root


def _target_framework(path: Path) -> str:
    root = _project_xml(path)
    if root.attrib != {"Sdk": "Microsoft.NET.Sdk"}:
        raise VerificationError(f"{path} must use only Microsoft.NET.Sdk")
    frameworks: list[str] = []

    def inspect(node: ET.Element, inherited_condition: bool = False) -> None:
        local_name = _xml_local_name(node.tag)
        has_condition = inherited_condition or any(
            _xml_local_name(attribute) == "Condition" for attribute in node.attrib
        )
        if local_name == "Import":
            raise VerificationError(f"{path} must not import TargetFramework overrides")
        if local_name == "Sdk":
            raise VerificationError(f"{path} must not declare additional SDK imports")
        if local_name == "TargetFrameworks":
            raise VerificationError(f"{path} must not declare TargetFrameworks")
        if local_name == "TargetFramework":
            if has_condition or node.attrib or node.text is None or not node.text.strip():
                raise VerificationError(
                    f"{path} must declare one unconditional TargetFramework"
                )
            frameworks.append(node.text.strip())
        for child in node:
            inspect(child, has_condition)

    inspect(root)
    if len(frameworks) != 1:
        raise VerificationError(f"{path} must declare one TargetFramework")
    return frameworks[0]


def _verify_shared_msbuild_properties(path: Path) -> None:
    root = _project_xml(path)
    if root.attrib:
        raise VerificationError(f"{path} must not declare implicit SDK imports")
    for node in root.iter():
        local_name = _xml_local_name(node.tag)
        if local_name in {"Import", "Sdk", "TargetFramework", "TargetFrameworks"}:
            raise VerificationError(
                f"{path} must not import or override target frameworks"
            )


def _workflow_dotnet_version(path: Path) -> str:
    contents = _read_bounded(path)
    lines = contents.splitlines()
    significant = [line for line in lines if not line.lstrip().startswith("#")]
    if sum(line.count("dotnet-version") for line in significant) != 1:
        raise VerificationError(f"{path} must declare one active dotnet-version")
    fields = WORKFLOW_DOTNET_FIELD_PATTERN.findall(contents)
    values = WORKFLOW_DOTNET_VALUE_PATTERN.findall(contents)
    if len(fields) != 1 or len(values) != 1:
        raise VerificationError(f"{path} must declare one active quoted dotnet-version")
    setup_steps = [
        (index, match)
        for index, line in enumerate(lines)
        if (match := SETUP_DOTNET_STEP_PATTERN.fullmatch(line)) is not None
    ]
    if len(setup_steps) != 1:
        raise VerificationError(f"{path} must contain one actions/setup-dotnet step")
    setup_index, setup_match = setup_steps[0]
    setup_indent = len(setup_match.group("indent").expandtabs(8))
    step_end = len(lines)
    for index in range(setup_index + 1, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" \t"))
        if indent <= setup_indent:
            step_end = index
            break
    field_indices = [
        index
        for index in range(setup_index + 1, step_end)
        if WORKFLOW_DOTNET_VALUE_PATTERN.fullmatch(lines[index]) is not None
    ]
    if len(field_indices) != 1:
        raise VerificationError(
            f"{path} must bind dotnet-version to actions/setup-dotnet"
        )
    field_index = field_indices[0]
    field_indent = len(lines[field_index]) - len(lines[field_index].lstrip(" \t"))
    with_indices = [
        index
        for index in range(setup_index + 1, field_index)
        if lines[index].strip() == "with:"
        and len(lines[index]) - len(lines[index].lstrip(" \t")) == setup_indent + 2
    ]
    if len(with_indices) != 1 or field_indent != setup_indent + 4:
        raise VerificationError(
            f"{path} must bind dotnet-version under setup-dotnet with"
        )
    return values[0][1]


def _verify_msbuild_ancestors(root: Path, project_path: Path) -> None:
    windows_root = root / "platform/windows"
    canonical_props = windows_root / "Directory.Build.props"
    directory = project_path.parent
    applicable_props: Path | None = None
    while directory == root or root in directory.parents:
        props = directory / "Directory.Build.props"
        if props.exists() or props.is_symlink():
            applicable_props = props
            break
        directory = directory.parent
    if applicable_props != canonical_props:
        raise VerificationError(
            f"{project_path} must inherit platform/windows/Directory.Build.props"
        )

    directory = project_path.parent
    while directory == root or root in directory.parents:
        targets = directory / "Directory.Build.targets"
        if targets.exists() or targets.is_symlink():
            raise VerificationError(f"{targets} may override target frameworks")
        directory = directory.parent


def verify_project(root: Path, metadata: bytes) -> DotNetRelease:
    root = root.resolve()
    release = latest_dotnet_release(metadata)
    global_json_path = root / "global.json"
    global_json = _strict_json(
        _read_bounded_bytes(global_json_path, MAX_PROJECT_FILE_BYTES),
        "global.json",
    )
    expected_global = {
        "sdk": {
            "version": release.sdk,
            "rollForward": "disable",
            "allowPrerelease": False,
        }
    }
    if global_json != expected_global:
        raise VerificationError(
            f"global.json must pin exact latest stable .NET SDK {release.sdk}"
        )

    tfm = f"net{release.channel_text}"
    expected_frameworks = {
        Path("platform/windows/src/XanhBrowser.Core/XanhBrowser.Core.csproj"): tfm,
        Path("platform/windows/tests/XanhBrowser.Core.Tests/XanhBrowser.Core.Tests.csproj"): tfm,
        Path("platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj"): (
            f"{tfm}-windows10.0.19041.0"
        ),
    }
    _verify_shared_msbuild_properties(root / "platform/windows/Directory.Build.props")
    for relative, expected in expected_frameworks.items():
        project_path = root / relative
        _verify_msbuild_ancestors(root, project_path)
        actual = _target_framework(project_path)
        if actual != expected:
            raise VerificationError(
                f"{relative} targets {actual}; latest stable target is {expected}"
            )

    for relative in (Path(".github/workflows/windows.yml"), Path(".github/workflows/codeql.yml")):
        if _workflow_dotnet_version(root / relative) != release.sdk:
            raise VerificationError(f"{relative} must install exact .NET SDK {release.sdk}")
    return release


def fetch_official_metadata(url: str = DOTNET_INDEX_URL) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise VerificationError(".NET index URL must be credential-free HTTPS")
    request = urllib.request.Request(url, headers={"User-Agent": "XanhBrowser-DotNet-Verifier/1.0"})
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
                raise VerificationError(".NET index redirected outside its official origin")
            length = response.headers.get("Content-Length")
            if length is not None and int(length) > MAX_REMOTE_BYTES:
                raise VerificationError(".NET releases index exceeds the 1 MiB safety limit")
            contents = response.read(MAX_REMOTE_BYTES + 1)
    except (OSError, ValueError, urllib.error.URLError) as error:
        raise VerificationError(f"cannot query official .NET releases index: {error}") from error
    if len(contents) > MAX_REMOTE_BYTES:
        raise VerificationError(".NET releases index exceeds the 1 MiB safety limit")
    return contents


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail when Xanh does not use the latest supported stable .NET SDK."
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--metadata-file", type=Path)
    parser.add_argument("--metadata-url", default=DOTNET_INDEX_URL)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        metadata = (
            _read_bounded_bytes(arguments.metadata_file, MAX_REMOTE_BYTES)
            if arguments.metadata_file
            else fetch_official_metadata(arguments.metadata_url)
        )
        release = verify_project(arguments.root, metadata)
    except (OSError, VerificationError) as error:
        print(f".NET latest-stable verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"Verified latest supported stable .NET {release.runtime} / SDK {release.sdk}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
