#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import uuid
import zipfile
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote


MAX_AAR_ENTRIES = 100_000
MAX_AAR_UNCOMPRESSED_BYTES = 16 * 1024 * 1024 * 1024
MAX_EVIDENCE_JSON_BYTES = 16 * 1024 * 1024
MAX_SBOM_JSON_BYTES = 512 * 1024 * 1024
MAX_SOURCE_ARCHIVE_BYTES = 32 * 1024 * 1024 * 1024
MAX_SOURCE_ARCHIVE_ENTRIES = 500_000
MAX_SOURCE_ARCHIVE_UNCOMPRESSED_BYTES = 64 * 1024 * 1024 * 1024
MAX_REQUIRED_SOURCE_FILE_BYTES = 16 * 1024 * 1024
READ_CHUNK_BYTES = 1024 * 1024
SHA1_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SEMVER_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SUPPORTED_ABIS = ("arm64-v8a", "x86_64")
WPEWEBKIT_SOURCE_SHA256 = "b2bafef2751625b7fdf530f230ff0f542ff0eeba3590c3a989d931b2a55c858e"
KNOWN_ANDROID_ABIS = {
    "arm64-v8a",
    "armeabi-v7a",
    "riscv64",
    "x86",
    "x86_64",
}
ELF_MACHINE_BY_ABI = {
    "arm64-v8a": (183, "AArch64"),
    "x86_64": (62, "X86-64"),
}


class EvidenceError(RuntimeError):
    pass


def read_single_line(path: Path, pattern: re.Pattern[str], label: str) -> str:
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as error:
        raise EvidenceError(f"cannot read {label}: {error}") from error
    lines = contents.splitlines()
    if len(lines) != 1 or pattern.fullmatch(lines[0]) is None:
        raise EvidenceError(f"{label} must contain exactly one valid line")
    return lines[0]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(READ_CHUNK_BYTES):
                digest.update(chunk)
    except OSError as error:
        raise EvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def run_git(source: Path, *arguments: str, environment: dict[str, str] | None = None) -> str:
    try:
        completed = subprocess.run(
            ["git", "-C", str(source), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
    except OSError as error:
        raise EvidenceError(f"cannot execute Git: {error}") from error
    if completed.returncode:
        detail = completed.stderr.strip() or f"Git exited with {completed.returncode}"
        raise EvidenceError(detail)
    return completed.stdout.strip()


def read_git_blob(source: Path, revision: str, relative_path: str) -> bytes:
    try:
        completed = subprocess.run(
            ["git", "-C", str(source), "show", f"{revision}:{relative_path}"],
            check=False,
            capture_output=True,
        )
    except OSError as error:
        raise EvidenceError(f"cannot execute Git: {error}") from error
    if completed.returncode:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise EvidenceError(detail or f"cannot read Git blob {relative_path}")
    return completed.stdout


def validate_exact_patched_tree(source: Path, patch: Path, label: str) -> None:
    if not patch.is_file():
        raise EvidenceError(f"{label} patch is missing")
    with tempfile.TemporaryDirectory(prefix="xanh-evidence-index-") as temporary:
        expected_index = Path(temporary) / "expected.index"
        base_environment = os.environ.copy()

        expected_environment = {**base_environment, "GIT_INDEX_FILE": str(expected_index)}
        run_git(source, "read-tree", "HEAD", environment=expected_environment)
        run_git(
            source,
            "apply",
            "--cached",
            "--binary",
            str(patch),
            environment=expected_environment,
        )
        expected_paths = run_git(
            source,
            "diff-index",
            "--cached",
            "--name-only",
            "HEAD",
            environment=expected_environment,
        ).splitlines()
        if not expected_paths or any(not path for path in expected_paths):
            raise EvidenceError(f"{label} patch does not contain a tracked source delta")

        expected_existing_paths = {
            path
            for path in expected_paths
            if run_git(source, "ls-tree", "--name-only", "HEAD", "--", path) == path
        }
        actual_modified_paths = set(
            run_git(source, "diff", "--name-only", "HEAD", "--").splitlines()
        )
        actual_staged_paths = set(
            run_git(source, "diff", "--cached", "--name-only", "HEAD", "--").splitlines()
        )
        if actual_staged_paths or actual_modified_paths != expected_existing_paths:
            raise EvidenceError(
                f"{label} tracked source tree contains changes outside the reviewed patch"
            )
        for path in expected_paths:
            expected_entry = run_git(
                source,
                "ls-files",
                "--stage",
                "--",
                path,
                environment=expected_environment,
            )
            match = re.fullmatch(r"([0-9]{6}) ([0-9a-f]{40}) 0\t(.+)", expected_entry)
            if match is None or match.group(3) != path:
                raise EvidenceError(f"cannot resolve expected {label} source entry: {path}")
            actual_path = source / path
            if not actual_path.exists() and not actual_path.is_symlink():
                raise EvidenceError(f"{label} patched source entry is missing: {path}")
            actual_hash = run_git(source, "hash-object", "--", path)
            actual_mode = "120000" if actual_path.is_symlink() else (
                "100755" if os.access(actual_path, os.X_OK) else "100644"
            )
            if actual_hash != match.group(2) or actual_mode != match.group(1):
                raise EvidenceError(f"{label} patched source entry drifted: {path}")


def validate_source_archive_path(name: str, label: str) -> PurePosixPath:
    if not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise EvidenceError(f"unsafe {label} archive path: {name!r}")
    normalized_name = name[:-1] if name.endswith("/") else name
    if not normalized_name:
        raise EvidenceError(f"unsafe {label} archive path: {name!r}")
    path = PurePosixPath(normalized_name)
    if any(part in ("", ".", "..") for part in path.parts):
        raise EvidenceError(f"unsafe {label} archive path: {name!r}")
    return path


def validate_source_archive(
    archive_path: Path,
    label: str,
    expected_prefix: str | None,
    required_files: dict[str, bytes | str],
    required_suffixes: dict[str, str] | None = None,
) -> dict[str, Any]:
    try:
        archive_size = archive_path.stat().st_size
    except OSError as error:
        raise EvidenceError(f"cannot inspect {label}: {error}") from error
    if archive_size <= 0 or archive_size > MAX_SOURCE_ARCHIVE_BYTES:
        raise EvidenceError(f"{label} is empty or exceeds the 32 GiB safety limit")

    names: set[str] = set()
    regular_members: dict[str, tarfile.TarInfo] = {}
    required_checksums: dict[str, str] = {}
    prefixes: set[str] = set()
    total_size = 0
    try:
        archive = tarfile.open(archive_path, mode="r:*")
    except (OSError, tarfile.TarError) as error:
        raise EvidenceError(f"cannot open {label}: {error}") from error
    with archive:
        members = archive.getmembers()
        if not members or len(members) > MAX_SOURCE_ARCHIVE_ENTRIES:
            raise EvidenceError(f"{label} entry count is empty or exceeds 500,000")
        for member in members:
            path = validate_source_archive_path(member.name, label)
            canonical_name = path.as_posix()
            if canonical_name in names:
                raise EvidenceError(f"duplicate {label} archive entry: {canonical_name}")
            names.add(canonical_name)
            prefixes.add(path.parts[0])
            if member.islnk() or member.ischr() or member.isblk() or member.isfifo():
                raise EvidenceError(f"unsafe special entry in {label}: {canonical_name}")
            if member.issym():
                target = PurePosixPath(member.linkname)
                if target.is_absolute():
                    raise EvidenceError(f"absolute symlink in {label}: {canonical_name}")
                depth = 0
                for part in (*path.parent.parts[1:], *target.parts):
                    if part in ("", "."):
                        continue
                    if part == "..":
                        depth -= 1
                    else:
                        depth += 1
                    if depth < 0:
                        raise EvidenceError(f"escaping symlink in {label}: {canonical_name}")
                continue
            if member.isfile():
                total_size += member.size
                if total_size > MAX_SOURCE_ARCHIVE_UNCOMPRESSED_BYTES:
                    raise EvidenceError(f"{label} expands beyond the 64 GiB safety limit")
                regular_members[canonical_name] = member
            elif not member.isdir():
                raise EvidenceError(f"unsupported entry type in {label}: {canonical_name}")

        if expected_prefix is not None:
            if prefixes != {expected_prefix}:
                raise EvidenceError(f"{label} does not use the exact revision prefix")
            prefix = expected_prefix
        elif len(prefixes) == 1:
            prefix = next(iter(prefixes))
            if re.fullmatch(r"cerbero-[0-9]+\.[0-9]+\.[0-9]+", prefix) is None:
                raise EvidenceError(f"{label} has an unexpected top-level prefix")
        else:
            raise EvidenceError(f"{label} must contain exactly one top-level prefix")

        def read_required(member_name: str) -> bytes:
            member = regular_members.get(member_name)
            if member is None or member.size > MAX_REQUIRED_SOURCE_FILE_BYTES:
                raise EvidenceError(f"{label} is missing bounded file {member_name}")
            stream = archive.extractfile(member)
            if stream is None:
                raise EvidenceError(f"cannot read {member_name} from {label}")
            contents = stream.read(MAX_REQUIRED_SOURCE_FILE_BYTES + 1)
            if len(contents) != member.size:
                raise EvidenceError(f"truncated file {member_name} in {label}")
            return contents

        for relative_name, expected in required_files.items():
            member_name = f"{prefix}/{relative_name}"
            contents = read_required(member_name)
            required_checksums[relative_name] = hashlib.sha256(contents).hexdigest()
            if isinstance(expected, bytes):
                if contents != expected:
                    raise EvidenceError(f"{label} file content drifted: {relative_name}")
            else:
                try:
                    source_text = contents.decode("utf-8", errors="strict")
                except UnicodeDecodeError as error:
                    raise EvidenceError(
                        f"{label} file is not UTF-8: {relative_name}"
                    ) from error
                if expected not in source_text:
                    raise EvidenceError(f"{label} file marker is missing: {relative_name}")

        for role, suffix in (required_suffixes or {}).items():
            matches = [name for name in regular_members if name.endswith(suffix)]
            if len(matches) != 1:
                raise EvidenceError(f"{label} must contain exactly one {role}")
            member_name = matches[0]
            member = regular_members[member_name]
            stream = archive.extractfile(member)
            if stream is None:
                raise EvidenceError(f"cannot read {role} from {label}")
            digest = hashlib.sha256()
            while chunk := stream.read(READ_CHUNK_BYTES):
                digest.update(chunk)
            if role == "WPE WebKit source tarball" and digest.hexdigest() != WPEWEBKIT_SOURCE_SHA256:
                raise EvidenceError("Cerbero bundle contains the wrong WPE WebKit source tarball")

    return {
        "entries": len(names),
        "expanded_size": total_size,
        "required_file_sha256": dict(sorted(required_checksums.items())),
        "top_level_prefix": prefix,
    }


def validate_archive_path(name: str) -> None:
    if not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise EvidenceError(f"unsafe AAR entry path: {name!r}")
    normalized_name = name[:-1] if name.endswith("/") else name
    if not normalized_name or any(part in ("", ".", "..") for part in normalized_name.split("/")):
        raise EvidenceError(f"unsafe AAR entry path: {name!r}")


def archive_inventory(
    aar: Path, runtime_version: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    entries: list[dict[str, Any]] = []
    native_libraries: list[dict[str, Any]] = []
    names: set[str] = set()
    total_size = 0
    observed_abis: set[str] = set()
    runtime_marker_abis: set[str] = set()
    runtime_marker = f"wpewebkit-{runtime_version}".encode("ascii")
    required_entries = {"AndroidManifest.xml", "classes.jar"}

    try:
        archive = zipfile.ZipFile(aar)
    except (OSError, zipfile.BadZipFile) as error:
        raise EvidenceError(f"cannot open AAR {aar}: {error}") from error

    with archive:
        infos = archive.infolist()
        if not infos or len(infos) > MAX_AAR_ENTRIES:
            raise EvidenceError("AAR entry count is empty or exceeds 100,000")
        for info in infos:
            validate_archive_path(info.filename)
            if info.filename in names:
                raise EvidenceError(f"duplicate AAR entry: {info.filename}")
            names.add(info.filename)
            if info.is_dir():
                continue
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise EvidenceError(f"symbolic links are forbidden in the AAR: {info.filename}")
            total_size += info.file_size
            if total_size > MAX_AAR_UNCOMPRESSED_BYTES:
                raise EvidenceError("AAR expands beyond the 16 GiB safety limit")

            digest = hashlib.sha256()
            marker_found = False
            marker_overlap = b""
            elf_header = b""
            try:
                with archive.open(info, "r") as stream:
                    while chunk := stream.read(READ_CHUNK_BYTES):
                        digest.update(chunk)
                        if len(elf_header) < 20:
                            elf_header += chunk[: 20 - len(elf_header)]
                        marker_buffer = marker_overlap + chunk
                        if runtime_marker in marker_buffer:
                            marker_found = True
                        marker_overlap = marker_buffer[-(len(runtime_marker) - 1) :]
            except (OSError, RuntimeError, zipfile.BadZipFile) as error:
                raise EvidenceError(f"cannot read AAR entry {info.filename}: {error}") from error
            checksum = digest.hexdigest()
            entry = {
                "path": info.filename,
                "sha256": checksum,
                "size": info.file_size,
            }
            entries.append(entry)

            if info.filename.endswith(".so"):
                parts = set(PurePosixPath(info.filename).parts)
                abis = parts.intersection(KNOWN_ANDROID_ABIS)
                if len(abis) != 1:
                    raise EvidenceError(
                        f"native library must belong to exactly one known ABI: {info.filename}"
                    )
                abi = next(iter(abis))
                if abi not in SUPPORTED_ABIS:
                    raise EvidenceError(f"unsupported Android ABI in AAR: {abi}")
                expected_machine, machine_name = ELF_MACHINE_BY_ABI[abi]
                if (
                    len(elf_header) < 20
                    or elf_header[:4] != b"\x7fELF"
                    or elf_header[4] != 2
                    or elf_header[5] != 1
                    or int.from_bytes(elf_header[18:20], "little") != expected_machine
                ):
                    raise EvidenceError(
                        f"native library ELF machine does not match {abi}: {info.filename}"
                    )
                observed_abis.add(abi)
                native_libraries.append({**entry, "abi": abi, "elf_machine": machine_name})
                if (
                    PurePosixPath(info.filename).name.startswith("libWPEWebKit-2.0")
                    and marker_found
                ):
                    runtime_marker_abis.add(abi)

    missing_entries = required_entries.difference(names)
    if missing_entries:
        raise EvidenceError(
            f"AAR is missing required entries: {', '.join(sorted(missing_entries))}"
        )
    missing_abis = set(SUPPORTED_ABIS).difference(observed_abis)
    if missing_abis:
        raise EvidenceError(
            f"AAR is missing native libraries for: {', '.join(sorted(missing_abis))}"
        )
    missing_runtime_markers = set(SUPPORTED_ABIS).difference(runtime_marker_abis)
    if missing_runtime_markers:
        raise EvidenceError(
            "WPE runtime marker is missing from libWPEWebKit for: "
            + ", ".join(sorted(missing_runtime_markers))
        )

    entries.sort(key=lambda value: value["path"])
    native_libraries.sort(key=lambda value: value["path"])
    return entries, native_libraries


def copy_support_file(source: Path, destination: Path) -> dict[str, Any]:
    try:
        is_valid = source.is_file() and source.stat().st_size > 0
    except OSError as error:
        raise EvidenceError(
            f"cannot inspect supporting evidence file {source}: {error}"
        ) from error
    if not is_valid:
        raise EvidenceError(f"supporting evidence file does not exist: {source}")
    try:
        shutil.copyfile(source, destination)
        os.chmod(destination, 0o644)
    except OSError as error:
        raise EvidenceError(f"cannot copy evidence file {source}: {error}") from error
    return {
        "file": destination.name,
        "sha256": sha256_file(destination),
        "size": destination.stat().st_size,
    }


def cyclonedx_component(entry: dict[str, Any], root_reference: str) -> dict[str, Any]:
    encoded_path = quote(entry["path"], safe="")
    reference = f"{root_reference}/file/{encoded_path}"
    return {
        "type": "file",
        "bom-ref": reference,
        "name": entry["path"],
        "hashes": [{"alg": "SHA-256", "content": entry["sha256"]}],
        "properties": [{"name": "xanh:archive-size", "value": str(entry["size"])}],
    }


def build_sbom(
    entries: list[dict[str, Any]],
    artifact_checksum: str,
    wpeview_version: str,
    runtime: str,
    revision: str,
    cerbero_revision: str,
    patch_checksum: str,
    commit_timestamp: str,
) -> dict[str, Any]:
    root_reference = (
        f"pkg:maven/org.wpewebkit.wpeview/wpeview@{wpeview_version}"
        f"?xanh_patch={patch_checksum}"
    )
    components = [cyclonedx_component(entry, root_reference) for entry in entries]
    component_references = [component["bom-ref"] for component in components]
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, artifact_checksum)}",
        "version": 1,
        "metadata": {
            "timestamp": commit_timestamp,
            "component": {
                "type": "library",
                "bom-ref": root_reference,
                "group": "org.wpewebkit.wpeview",
                "name": "wpeview",
                "version": wpeview_version,
                "hashes": [{"alg": "SHA-256", "content": artifact_checksum}],
                "properties": [
                    {"name": "xanh:wpe-android-revision", "value": revision},
                    {"name": "xanh:cerbero-revision", "value": cerbero_revision},
                    {"name": "xanh:wpewebkit-version", "value": runtime},
                    {"name": "xanh:source-patch-sha256", "value": patch_checksum},
                ],
            },
        },
        "components": components,
        "dependencies": [{"ref": root_reference, "dependsOn": component_references}],
    }


def create_evidence(
    root: Path,
    source: Path,
    aar: Path,
    upstream_source: Path,
    cerbero_source: Path,
    corresponding_source: Path,
    build_environment: Path,
    build_log: Path,
    alignment_evidence: Path,
    output: Path,
) -> Path:
    if output.exists():
        if not output.is_dir() or any(output.iterdir()):
            raise EvidenceError("output directory must be absent or empty")
    else:
        output.mkdir(parents=True, mode=0o755)

    fork = root / "app-webkit/wpe-fork"
    revision = read_single_line(fork / "WPE_ANDROID_REVISION", SHA1_PATTERN, "WPE revision")
    cerbero_revision = read_single_line(
        fork / "CERBERO_REVISION", SHA1_PATTERN, "Cerbero revision"
    )
    runtime = read_single_line(fork / "WPE_RUNTIME_VERSION", SEMVER_PATTERN, "WPE runtime")
    baseline = read_single_line(root / "WEBKITGTK_MIN_VERSION", SEMVER_PATTERN, "WebKit baseline")
    wpeview_version = read_single_line(
        root / "app-webkit/WPEVIEW_VERSION", SEMVER_PATTERN, "WPEView version"
    )
    if runtime != baseline:
        raise EvidenceError("WPE runtime does not match the shared WebKit security baseline")
    if run_git(source, "rev-parse", "HEAD") != revision:
        raise EvidenceError("source checkout does not match the locked WPE Android revision")
    commit_timestamp = run_git(source, "show", "-s", "--format=%cI", revision)
    try:
        datetime.fromisoformat(commit_timestamp)
    except ValueError as error:
        raise EvidenceError("source commit timestamp is invalid") from error

    patch = fork / "patches/xanh-isolated-bridge.patch"
    cerbero_patch = fork / "patches/cerbero-wpewebkit-2.52.6.patch"
    validate_exact_patched_tree(source, patch, "WPE Android")
    run_git(source, "diff", "--check")
    cerbero_checkout = source / "build/cerbero"
    if run_git(cerbero_checkout, "rev-parse", "HEAD") != cerbero_revision:
        raise EvidenceError("built Cerbero checkout does not match the locked revision")
    validate_exact_patched_tree(cerbero_checkout, cerbero_patch, "Cerbero")
    run_git(cerbero_checkout, "diff", "--check")
    try:
        recipe = (cerbero_checkout / "recipes/wpewebkit.recipe").read_text(encoding="utf-8")
        android_config = (cerbero_checkout / "config/android.config").read_text(encoding="utf-8")
    except OSError as error:
        raise EvidenceError(f"cannot read the built Cerbero contract: {error}") from error
    if f"version = '{runtime}'" not in recipe or WPEWEBKIT_SOURCE_SHA256 not in recipe:
        raise EvidenceError("Cerbero WPE WebKit source version or checksum drifted")
    if "-Wl,-z,max-page-size=16384" not in android_config or (
        "-Wl,-z,common-page-size=16384" not in android_config
    ):
        raise EvidenceError("Cerbero Android linker alignment contract is missing")

    wpe_required_paths = (
        "README.md",
        "LICENSE.md",
        "gradle/wrapper/gradle-wrapper.properties",
        "gradle/libs.versions.toml",
        "tools/scripts/bootstrap.py",
        "wpeview/build.gradle",
    )
    wpe_archive = validate_source_archive(
        upstream_source,
        "WPE Android upstream source archive",
        f"wpe-android-{revision}",
        {path: read_git_blob(source, revision, path) for path in wpe_required_paths},
    )
    cerbero_required_paths = (
        "LICENSE.LGPL",
        "setup.py",
        "cerbero/commands/bundlesource.py",
        "config/android.config",
        "packages/wpewebkit.package",
        "packages/wpewebkit-core.package",
        "recipes/wpewebkit.recipe",
    )
    cerbero_archive = validate_source_archive(
        cerbero_source,
        "Cerbero upstream source archive",
        f"cerbero-{cerbero_revision}",
        {
            path: read_git_blob(cerbero_checkout, cerbero_revision, path)
            for path in cerbero_required_paths
        },
    )
    corresponding_archive = validate_source_archive(
        corresponding_source,
        "Cerbero corresponding-source bundle",
        None,
        {
            "LICENSE.LGPL": read_git_blob(cerbero_checkout, cerbero_revision, "LICENSE.LGPL"),
            "config/android.config": (cerbero_checkout / "config/android.config").read_bytes(),
            "packages/wpewebkit.package": (
                cerbero_checkout / "packages/wpewebkit.package"
            ).read_bytes(),
            "packages/wpewebkit-core.package": (
                cerbero_checkout / "packages/wpewebkit-core.package"
            ).read_bytes(),
            "recipes/wpewebkit.recipe": (
                cerbero_checkout / "recipes/wpewebkit.recipe"
            ).read_bytes(),
        },
        {"WPE WebKit source tarball": f"/sources/wpewebkit-{runtime}/wpewebkit-{runtime}.tar.xz"},
    )
    entries, native_libraries = archive_inventory(aar, runtime)
    artifact_checksum = sha256_file(aar)
    artifact_name = f"xanh-wpeview-{wpeview_version}-webkit-{runtime}.aar"
    artifact = copy_support_file(aar, output / artifact_name)

    supporting_files = {
        "wpe_android_upstream_source": copy_support_file(
            upstream_source, output / "wpe-android-upstream.tar.gz"
        ),
        "cerbero_upstream_source": copy_support_file(
            cerbero_source, output / "cerbero-upstream.tar.gz"
        ),
        "cerbero_corresponding_source": copy_support_file(
            corresponding_source, output / "cerbero-corresponding-source.tar.gz"
        ),
        "xanh_source_patch": copy_support_file(patch, output / "xanh-isolated-bridge.patch"),
        "cerbero_source_patch": copy_support_file(
            cerbero_patch, output / "cerbero-wpewebkit-2.52.6.patch"
        ),
        "build_environment": copy_support_file(
            build_environment, output / "build-environment.txt"
        ),
        "build_log": copy_support_file(build_log, output / "build.log"),
        "android_16k_alignment": copy_support_file(
            alignment_evidence, output / "wpe-16k-evidence.txt"
        ),
    }
    if artifact["sha256"] != artifact_checksum:
        raise EvidenceError("copied AAR checksum changed")

    checksum_file = output / f"{artifact_name}.sha256"
    checksum_file.write_text(f"{artifact_checksum}  {artifact_name}\n", encoding="utf-8")
    os.chmod(checksum_file, 0o644)

    patch_checksum = supporting_files["xanh_source_patch"]["sha256"]
    cerbero_patch_checksum = supporting_files["cerbero_source_patch"]["sha256"]
    sbom = build_sbom(
        entries,
        artifact_checksum,
        wpeview_version,
        runtime,
        revision,
        cerbero_revision,
        patch_checksum,
        commit_timestamp,
    )
    sbom_path = output / "wpeview-sbom.cdx.json"
    sbom_path.write_text(json.dumps(sbom, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(sbom_path, 0o644)

    evidence = {
        "schema": "io.github.lamppkk.xanhbrowser.wpe-build-evidence.v2",
        "artifact": {
            **artifact,
            "aar_entries": len(entries),
            "architectures": list(SUPPORTED_ABIS),
            "native_libraries": native_libraries,
        },
        "inputs": {
            "cerbero_revision": cerbero_revision,
            "cerbero_source_patch_sha256": cerbero_patch_checksum,
            "source_patch_sha256": patch_checksum,
            "webkit_security_baseline": baseline,
            "wpe_android_revision": revision,
            "wpe_runtime_version": runtime,
            "wpeview_version": wpeview_version,
        },
        "source_commit_timestamp": commit_timestamp,
        "source_archives": {
            "wpe_android_upstream_source": wpe_archive,
            "cerbero_upstream_source": cerbero_archive,
            "cerbero_corresponding_source": corresponding_archive,
        },
        "supporting_files": supporting_files,
        "sbom": {
            "file": sbom_path.name,
            "sha256": sha256_file(sbom_path),
            "size": sbom_path.stat().st_size,
        },
    }
    evidence_path = output / "wpe-build-evidence.json"
    evidence_path.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.chmod(evidence_path, 0o644)
    return evidence_path


def load_json_object(path: Path, maximum_bytes: int, label: str) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise EvidenceError(f"{label} must be a regular file")
    size = path.stat().st_size
    if size == 0 or size > maximum_bytes:
        raise EvidenceError(f"{label} is empty or exceeds its safety limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot parse {label}: {error}") from error
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must contain a JSON object")
    return value


def evidence_file(directory: Path, name: Any, expected_name: str) -> Path:
    if not isinstance(name, str) or name != expected_name or Path(name).name != name:
        raise EvidenceError(f"unexpected evidence filename: {name!r}")
    path = directory / name
    if not path.is_file() or path.is_symlink() or path.resolve().parent != directory.resolve():
        raise EvidenceError(f"evidence file is missing or unsafe: {name}")
    return path


def verify_file_record(
    directory: Path, record: Any, expected_name: str, label: str
) -> tuple[Path, dict[str, Any]]:
    if not isinstance(record, dict) or set(record) != {"file", "sha256", "size"}:
        raise EvidenceError(f"invalid {label} record")
    path = evidence_file(directory, record["file"], expected_name)
    if not isinstance(record["sha256"], str) or re.fullmatch(
        r"[0-9a-f]{64}", record["sha256"]
    ) is None:
        raise EvidenceError(f"invalid {label} checksum")
    if not isinstance(record["size"], int) or isinstance(record["size"], bool):
        raise EvidenceError(f"invalid {label} size")
    if record["size"] <= 0 or path.stat().st_size != record["size"]:
        raise EvidenceError(f"{label} size mismatch")
    if sha256_file(path) != record["sha256"]:
        raise EvidenceError(f"{label} checksum mismatch")
    return path, record


def verify_evidence(root: Path, directory: Path) -> Path:
    if not directory.is_dir() or directory.is_symlink():
        raise EvidenceError("evidence directory must be a real directory")
    manifest_path = evidence_file(directory, "wpe-build-evidence.json", "wpe-build-evidence.json")
    evidence = load_json_object(manifest_path, MAX_EVIDENCE_JSON_BYTES, "WPE build evidence")
    if set(evidence) != {
        "schema",
        "artifact",
        "inputs",
        "source_commit_timestamp",
        "source_archives",
        "supporting_files",
        "sbom",
    }:
        raise EvidenceError("WPE build evidence contains an unexpected schema")
    if evidence["schema"] != "io.github.lamppkk.xanhbrowser.wpe-build-evidence.v2":
        raise EvidenceError("unsupported WPE build evidence schema")

    fork = root / "app-webkit/wpe-fork"
    revision = read_single_line(fork / "WPE_ANDROID_REVISION", SHA1_PATTERN, "WPE revision")
    cerbero_revision = read_single_line(
        fork / "CERBERO_REVISION", SHA1_PATTERN, "Cerbero revision"
    )
    runtime = read_single_line(fork / "WPE_RUNTIME_VERSION", SEMVER_PATTERN, "WPE runtime")
    baseline = read_single_line(root / "WEBKITGTK_MIN_VERSION", SEMVER_PATTERN, "WebKit baseline")
    wpeview_version = read_single_line(
        root / "app-webkit/WPEVIEW_VERSION", SEMVER_PATTERN, "WPEView version"
    )
    patch_checksum = sha256_file(fork / "patches/xanh-isolated-bridge.patch")
    cerbero_patch_checksum = sha256_file(
        fork / "patches/cerbero-wpewebkit-2.52.6.patch"
    )
    expected_inputs = {
        "cerbero_revision": cerbero_revision,
        "cerbero_source_patch_sha256": cerbero_patch_checksum,
        "source_patch_sha256": patch_checksum,
        "webkit_security_baseline": baseline,
        "wpe_android_revision": revision,
        "wpe_runtime_version": runtime,
        "wpeview_version": wpeview_version,
    }
    if runtime != baseline or evidence["inputs"] != expected_inputs:
        raise EvidenceError("build evidence does not match the current locked inputs")

    commit_timestamp = evidence["source_commit_timestamp"]
    if not isinstance(commit_timestamp, str):
        raise EvidenceError("source commit timestamp is missing")
    try:
        datetime.fromisoformat(commit_timestamp)
    except ValueError as error:
        raise EvidenceError("source commit timestamp is invalid") from error

    artifact_name = f"xanh-wpeview-{wpeview_version}-webkit-{runtime}.aar"
    artifact_record = evidence["artifact"]
    if not isinstance(artifact_record, dict):
        raise EvidenceError("artifact record is invalid")
    artifact_path = evidence_file(directory, artifact_record.get("file"), artifact_name)
    artifact_checksum = sha256_file(artifact_path)
    entries, native_libraries = archive_inventory(artifact_path, runtime)
    expected_artifact = {
        "file": artifact_name,
        "sha256": artifact_checksum,
        "size": artifact_path.stat().st_size,
        "aar_entries": len(entries),
        "architectures": list(SUPPORTED_ABIS),
        "native_libraries": native_libraries,
    }
    if artifact_record != expected_artifact:
        raise EvidenceError("artifact inventory does not match the evidence manifest")

    expected_supporting_names = {
        "wpe_android_upstream_source": "wpe-android-upstream.tar.gz",
        "cerbero_upstream_source": "cerbero-upstream.tar.gz",
        "cerbero_corresponding_source": "cerbero-corresponding-source.tar.gz",
        "xanh_source_patch": "xanh-isolated-bridge.patch",
        "cerbero_source_patch": "cerbero-wpewebkit-2.52.6.patch",
        "build_environment": "build-environment.txt",
        "build_log": "build.log",
        "android_16k_alignment": "wpe-16k-evidence.txt",
    }
    supporting_files = evidence["supporting_files"]
    if not isinstance(supporting_files, dict) or set(supporting_files) != set(
        expected_supporting_names
    ):
        raise EvidenceError("supporting evidence set is incomplete")
    verified_support: dict[str, Path] = {}
    for role, expected_name in expected_supporting_names.items():
        verified_support[role], _ = verify_file_record(
            directory, supporting_files[role], expected_name, role
        )
    if sha256_file(verified_support["xanh_source_patch"]) != patch_checksum:
        raise EvidenceError("packaged Xanh source patch does not match the repository")
    if sha256_file(verified_support["cerbero_source_patch"]) != cerbero_patch_checksum:
        raise EvidenceError("packaged Cerbero source patch does not match the repository")

    source_archives = evidence["source_archives"]
    if not isinstance(source_archives, dict) or set(source_archives) != {
        "wpe_android_upstream_source",
        "cerbero_upstream_source",
        "cerbero_corresponding_source",
    }:
        raise EvidenceError("source archive evidence set is incomplete")
    verified_archive_metadata = {
        "wpe_android_upstream_source": validate_source_archive(
            verified_support["wpe_android_upstream_source"],
            "WPE Android upstream source archive",
            f"wpe-android-{revision}",
            {
                "README.md": "WPE",
                "LICENSE.md": "GNU LESSER GENERAL PUBLIC LICENSE",
                "gradle/wrapper/gradle-wrapper.properties": "gradle-8.12-bin.zip",
                "gradle/libs.versions.toml": 'target-android-sdk = "35"',
                "tools/scripts/bootstrap.py": 'default_version = "2.50.6"',
                "wpeview/build.gradle": "alias libs.plugins.android.library",
            },
        ),
        "cerbero_upstream_source": validate_source_archive(
            verified_support["cerbero_upstream_source"],
            "Cerbero upstream source archive",
            f"cerbero-{cerbero_revision}",
            {
                "LICENSE.LGPL": "GNU LIBRARY GENERAL PUBLIC LICENSE",
                "setup.py": "extended_sdist",
                "cerbero/commands/bundlesource.py": "class BundleSource",
                "config/android.config": "--undefined-version '",
                "packages/wpewebkit.package": "version = '2.51.93'",
                "packages/wpewebkit-core.package": "version = '2.51.93'",
                "recipes/wpewebkit.recipe": "version = '2.51.93'",
            },
        ),
        "cerbero_corresponding_source": validate_source_archive(
            verified_support["cerbero_corresponding_source"],
            "Cerbero corresponding-source bundle",
            None,
            {
                "LICENSE.LGPL": "GNU LIBRARY GENERAL PUBLIC LICENSE",
                "config/android.config": "-Wl,-z,max-page-size=16384",
                "packages/wpewebkit.package": f"version = '{runtime}'",
                "packages/wpewebkit-core.package": f"version = '{runtime}'",
                "recipes/wpewebkit.recipe": WPEWEBKIT_SOURCE_SHA256,
            },
            {
                "WPE WebKit source tarball": (
                    f"/sources/wpewebkit-{runtime}/wpewebkit-{runtime}.tar.xz"
                )
            },
        ),
    }
    if source_archives != verified_archive_metadata:
        raise EvidenceError("source archive inventory does not match the evidence manifest")
    if verified_support["build_environment"].stat().st_size > 1024 * 1024:
        raise EvidenceError("build environment record exceeds 1 MiB")
    environment_text = verified_support["build_environment"].read_text(encoding="utf-8")
    for required_line in (
        "schema=io.github.lamppkk.xanhbrowser.wpe-build-environment.v1",
        f"wpe_android_revision={revision}",
        f"wpe_runtime_version={runtime}",
    ):
        if required_line not in environment_text.splitlines():
            raise EvidenceError(f"build environment is missing {required_line}")
    if verified_support["android_16k_alignment"].stat().st_size > 1024 * 1024:
        raise EvidenceError("16 KiB alignment record exceeds 1 MiB")
    alignment_text = verified_support["android_16k_alignment"].read_text(encoding="utf-8")
    if "Verified 16 KiB ELF alignment for " not in alignment_text:
        raise EvidenceError("16 KiB alignment evidence is incomplete")

    sbom_path, sbom_record = verify_file_record(
        directory, evidence["sbom"], "wpeview-sbom.cdx.json", "SBOM"
    )
    sbom = load_json_object(sbom_path, MAX_SBOM_JSON_BYTES, "WPE CycloneDX SBOM")
    expected_sbom = build_sbom(
        entries,
        artifact_checksum,
        wpeview_version,
        runtime,
        revision,
        cerbero_revision,
        patch_checksum,
        commit_timestamp,
    )
    if sbom != expected_sbom:
        raise EvidenceError("CycloneDX SBOM does not match the AAR inventory")
    if sbom_record["sha256"] != sha256_file(sbom_path):
        raise EvidenceError("SBOM record checksum changed during verification")

    checksum_path = evidence_file(
        directory, f"{artifact_name}.sha256", f"{artifact_name}.sha256"
    )
    expected_checksum_line = f"{artifact_checksum}  {artifact_name}\n"
    if checksum_path.read_text(encoding="utf-8") != expected_checksum_line:
        raise EvidenceError("AAR checksum sidecar does not match the artifact")
    return manifest_path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create fail-closed WPE Android AAR provenance and CycloneDX evidence."
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--verify-directory", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--aar", type=Path)
    parser.add_argument("--upstream-source", type=Path)
    parser.add_argument("--cerbero-source", type=Path)
    parser.add_argument("--corresponding-source", type=Path)
    parser.add_argument("--build-environment", type=Path)
    parser.add_argument("--build-log", type=Path)
    parser.add_argument("--alignment-evidence", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.verify_directory is not None:
            build_arguments = (
                arguments.source,
                arguments.aar,
                arguments.upstream_source,
                arguments.cerbero_source,
                arguments.corresponding_source,
                arguments.build_environment,
                arguments.build_log,
                arguments.alignment_evidence,
                arguments.output,
            )
            if any(value is not None for value in build_arguments):
                raise EvidenceError("verification mode cannot be combined with build inputs")
            path = verify_evidence(
                arguments.root.resolve(), arguments.verify_directory.resolve()
            )
            print(f"Verified WPE build evidence at {path}")
            return 0
        build_arguments = (
            arguments.source,
            arguments.aar,
            arguments.upstream_source,
            arguments.cerbero_source,
            arguments.corresponding_source,
            arguments.build_environment,
            arguments.build_log,
            arguments.alignment_evidence,
            arguments.output,
        )
        if any(value is None for value in build_arguments):
            raise EvidenceError("all build evidence inputs are required")
        path = create_evidence(
            arguments.root.resolve(),
            arguments.source.resolve(),  # type: ignore[union-attr]
            arguments.aar.resolve(),  # type: ignore[union-attr]
            arguments.upstream_source.resolve(),  # type: ignore[union-attr]
            arguments.cerbero_source.resolve(),  # type: ignore[union-attr]
            arguments.corresponding_source.resolve(),  # type: ignore[union-attr]
            arguments.build_environment.resolve(),  # type: ignore[union-attr]
            arguments.build_log.resolve(),  # type: ignore[union-attr]
            arguments.alignment_evidence.resolve(),  # type: ignore[union-attr]
            arguments.output.resolve(),  # type: ignore[union-attr]
        )
    except EvidenceError as error:
        print(f"WPE build evidence failed: {error}", file=sys.stderr)
        return 1
    print(f"Created WPE build evidence at {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
