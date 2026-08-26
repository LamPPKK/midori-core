#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import NamedTuple


OFFICIAL_WEBKIT_REPOSITORY = "https://github.com/WebKit/WebKit.git"
OFFICIAL_WEBKIT_RAW_ROOT = "https://raw.githubusercontent.com/WebKit/WebKit"
MAX_TAG_LIST_BYTES = 8 * 1024 * 1024
MAX_CONTRACT_SOURCE_BYTES = 1024 * 1024
POPUP_MOUSE_SOURCE = "Source/WebKit/Shared/WebMouseEvent.cpp"
POPUP_GLIB_SOURCE = "Source/WebKit/UIProcess/API/glib/WebKitNavigationAction.cpp"
SHA1_PATTERN = re.compile(r"^[0-9a-f]{40}$")
VERSION_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
TAG_PATTERN = re.compile(
    r"^refs/tags/webkitgtk-"
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(\^\{\})?$"
)


class VerificationError(RuntimeError):
    pass


class StableRelease(NamedTuple):
    version: tuple[int, int, int]
    tag: str
    revision: str


def _function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise VerificationError(f"missing WebKit contract function: {signature}")
    opening = source.find("{", start + len(signature))
    if opening < 0:
        raise VerificationError(f"missing function body: {signature}")
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise VerificationError(f"unterminated function body: {signature}")


def verify_popup_contract(mouse_source: str, glib_source: str) -> None:
    for name, source in ((POPUP_MOUSE_SOURCE, mouse_source), (POPUP_GLIB_SOURCE, glib_source)):
        if len(source.encode("utf-8")) > MAX_CONTRACT_SOURCE_BYTES:
            raise VerificationError(f"WebKit contract source exceeds 1 MiB: {name}")

    mouse_body = _function_body(
        mouse_source,
        "WebMouseEventButton mouseButton(const WebCore::NavigationAction& navigationAction)",
    )
    trusted = "mouseEventData->buttonDown && mouseEventData->isTrusted"
    trusted_index = mouse_body.find(trusted)
    button_index = mouse_body.find("return kit(mouseEventData->button);")
    none_index = mouse_body.find("return WebMouseEventButton::None;")
    if min(trusted_index, button_index, none_index) < 0 or not (
        trusted_index < button_index < none_index
    ):
        raise VerificationError(
            "WebKit popup contract no longer maps only trusted button-down events "
            "to a nonzero mouse button"
        )

    expected_returns = {
        "unsigned webkit_navigation_action_get_mouse_button("
        "WebKitNavigationAction* navigation)": (
            "return toWebKitMouseButton(navigation->action->mouseButton());"
        ),
        "gboolean webkit_navigation_action_is_user_gesture("
        "WebKitNavigationAction* navigation)": (
            "return navigation->action->isProcessingUserGesture();"
        ),
        "gboolean webkit_navigation_action_is_redirect("
        "WebKitNavigationAction* navigation)": "return navigation->action->isRedirect();",
    }
    for signature, expected in expected_returns.items():
        if expected not in _function_body(glib_source, signature):
            raise VerificationError(f"WebKit GLib popup contract changed: {signature}")


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
    stable_versions: dict[str, tuple[int, int, int]] = {}
    for line_number, line in enumerate(tag_list.splitlines(), start=1):
        fields = line.split()
        if len(fields) != 2:
            if line.strip():
                raise VerificationError(f"malformed ls-remote output at line {line_number}")
            continue
        revision, ref = fields
        if not SHA1_PATTERN.fullmatch(revision):
            raise VerificationError(f"invalid Git object ID at line {line_number}")
        match = TAG_PATTERN.fullmatch(ref)
        if match is None:
            continue

        version = tuple(int(part) for part in match.group(1, 2, 3))
        if version[1] % 2:
            continue
        tag = f"webkitgtk-{version[0]}.{version[1]}.{version[2]}"
        kind = "peeled" if match.group(4) else "direct"
        _record_revision(revisions, tag, kind, revision)
        stable_versions[tag] = version

    if not stable_versions:
        raise VerificationError("official tag list contains no stable WebKitGTK release")

    tag = max(stable_versions, key=lambda candidate: stable_versions[candidate])
    revision_values = revisions[tag]
    revision = revision_values.get("peeled", revision_values.get("direct"))
    if revision is None:
        raise VerificationError(f"no revision found for {tag}")
    return StableRelease(stable_versions[tag], tag, revision)


def _read_single_line(path: Path) -> str:
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as error:
        raise VerificationError(f"cannot read {path}: {error}") from error
    lines = contents.splitlines()
    if len(lines) != 1 or not lines[0]:
        raise VerificationError(f"{path} must contain exactly one non-empty line")
    return lines[0]


def verify_project(root: Path, tag_list: str) -> StableRelease:
    baseline = _read_single_line(root / "WEBKITGTK_MIN_VERSION")
    release_tag = _read_single_line(root / "platform/windows-webkit/WEBKIT_RELEASE_TAG")
    revision = _read_single_line(root / "platform/windows-webkit/WEBKIT_REVISION")
    match = VERSION_PATTERN.fullmatch(baseline)
    if match is None:
        raise VerificationError("WEBKITGTK_MIN_VERSION must be an exact semantic version")
    if not SHA1_PATTERN.fullmatch(revision):
        raise VerificationError("WEBKIT_REVISION must be one lowercase 40-character object ID")

    latest = latest_stable_release(tag_list)
    expected_version = ".".join(str(part) for part in latest.version)
    if baseline != expected_version:
        raise VerificationError(
            f"WebKit baseline {baseline} is stale; latest official stable is {expected_version}"
        )
    if release_tag != latest.tag:
        raise VerificationError(
            f"WinCairo tag {release_tag} does not match latest stable {latest.tag}"
        )
    if revision != latest.revision:
        raise VerificationError(
            f"WinCairo revision {revision} does not match peeled {latest.tag} revision "
            f"{latest.revision}"
        )
    return latest


def fetch_official_tags(repository: str) -> str:
    try:
        completed = subprocess.run(
            ["git", "ls-remote", "--tags", repository, "refs/tags/webkitgtk-*"],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError(f"cannot query official WebKit tags: {error}") from error
    if completed.returncode:
        detail = completed.stderr.strip() or f"git exited with {completed.returncode}"
        raise VerificationError(f"cannot query official WebKit tags: {detail}")
    return completed.stdout


def fetch_official_source(revision: str, path: str) -> str:
    if not SHA1_PATTERN.fullmatch(revision) or path not in {
        POPUP_MOUSE_SOURCE,
        POPUP_GLIB_SOURCE,
    }:
        raise VerificationError("invalid WebKit popup-contract source request")
    url = f"{OFFICIAL_WEBKIT_RAW_ROOT}/{revision}/{path}"
    request = urllib.request.Request(url, headers={"User-Agent": "xanh-browser-verifier/1"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read(MAX_CONTRACT_SOURCE_BYTES + 1)
    except (OSError, urllib.error.URLError) as error:
        raise VerificationError(f"cannot fetch official WebKit source {path}: {error}") from error
    if len(payload) > MAX_CONTRACT_SOURCE_BYTES:
        raise VerificationError(f"WebKit contract source exceeds 1 MiB: {path}")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"WebKit contract source is not UTF-8: {path}") from error


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail when Xanh's WebKit baseline is not the latest official stable tag."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="xanh-webkit repository root",
    )
    parser.add_argument(
        "--tags-file",
        type=Path,
        help="read git ls-remote output from a fixture instead of the network",
    )
    parser.add_argument(
        "--repository",
        default=OFFICIAL_WEBKIT_REPOSITORY,
        help="upstream repository; defaults to the official WebKit Git repository",
    )
    parser.add_argument(
        "--contract-source-directory",
        type=Path,
        help="read popup-contract source files from a pinned WebKit fixture",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.tags_file:
            tag_list = arguments.tags_file.read_text(encoding="utf-8")
        else:
            tag_list = fetch_official_tags(arguments.repository)
        release = verify_project(arguments.root.resolve(), tag_list)
        if arguments.contract_source_directory:
            source_root = arguments.contract_source_directory.resolve()
            mouse_source = (source_root / POPUP_MOUSE_SOURCE).read_text(encoding="utf-8")
            glib_source = (source_root / POPUP_GLIB_SOURCE).read_text(encoding="utf-8")
        else:
            mouse_source = fetch_official_source(release.revision, POPUP_MOUSE_SOURCE)
            glib_source = fetch_official_source(release.revision, POPUP_GLIB_SOURCE)
        verify_popup_contract(mouse_source, glib_source)
    except (OSError, VerificationError) as error:
        print(f"WebKit latest-stable verification failed: {error}", file=sys.stderr)
        return 1

    version = ".".join(str(part) for part in release.version)
    print(
        f"Verified latest stable WebKitGTK {version} at {release.revision} "
        "with the trusted popup-action contract"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
