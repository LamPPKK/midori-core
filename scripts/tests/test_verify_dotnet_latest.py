import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_dotnet_latest.py"
SPEC = importlib.util.spec_from_file_location("verify_dotnet_latest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def channel(
    version: str,
    runtime: str,
    sdk: str,
    *,
    phase: str = "active",
    release_type: str = "lts",
) -> dict[str, object]:
    return {
        "channel-version": version,
        "latest-release": runtime,
        "latest-release-date": "2026-08-11",
        "security": True,
        "latest-runtime": runtime,
        "latest-sdk": sdk,
        "product": ".NET",
        "support-phase": phase,
        "release-type": release_type,
        "releases.json": (
            "https://builds.dotnet.microsoft.com/dotnet/"
            f"release-metadata/{version}/releases.json"
        ),
        "supported-os.json": (
            "https://builds.dotnet.microsoft.com/dotnet/"
            f"release-metadata/{version}/supported-os.json"
        ),
        "eol-date": "2028-11-14",
    }


def metadata(*entries: dict[str, object]) -> bytes:
    return json.dumps(
        {
            "$schema": "https://json.schemastore.org/dotnet-releases-index.json",
            "releases-index": list(entries),
            "signature": {
                "expiration": "2099-11-09T22:12:48.3221052+00:00",
                "file": "releases-index.json.20260811221248.p7s",
            },
        }
    ).encode()


class DotNetLatestTests(unittest.TestCase):
    def fixture(self) -> bytes:
        return metadata(
            channel(
                "11.0",
                "11.0.0-preview.7",
                "11.0.100-preview.7.1",
                phase="preview",
                release_type="sts",
            ),
            channel("10.0", "10.0.11", "10.0.400"),
            channel("9.0", "9.0.19", "9.0.317", phase="maintenance", release_type="sts"),
            channel("8.0", "8.0.30", "8.0.424", phase="maintenance"),
        )

    def project(self, directory: str, *, sdk: str = "10.0.400") -> Path:
        root = Path(directory)
        (root / "platform/windows/src/XanhBrowser.Core").mkdir(parents=True)
        (root / "platform/windows/src/XanhBrowser.Windows").mkdir(parents=True)
        (root / "platform/windows/tests/XanhBrowser.Core.Tests").mkdir(parents=True)
        (root / ".github/workflows").mkdir(parents=True)
        (root / "platform/windows/Directory.Build.props").write_text(
            "<Project><PropertyGroup><Nullable>enable</Nullable>"
            "</PropertyGroup></Project>",
            encoding="utf-8",
        )
        (root / "global.json").write_text(
            json.dumps(
                {
                    "sdk": {
                        "version": sdk,
                        "rollForward": "disable",
                        "allowPrerelease": False,
                    }
                }
            ),
            encoding="utf-8",
        )
        for relative in (
            "platform/windows/src/XanhBrowser.Core/XanhBrowser.Core.csproj",
            "platform/windows/tests/XanhBrowser.Core.Tests/XanhBrowser.Core.Tests.csproj",
        ):
            (root / relative).write_text(
                "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup>"
                "<TargetFramework>net10.0</TargetFramework>"
                "</PropertyGroup></Project>",
                encoding="utf-8",
            )
        (root / "platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj").write_text(
            "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>"
            "net10.0-windows10.0.19041.0"
            "</TargetFramework></PropertyGroup></Project>",
            encoding="utf-8",
        )
        for workflow in ("windows.yml", "codeql.yml"):
            (root / ".github/workflows" / workflow).write_text(
                "steps:\n"
                "  - uses: actions/setup-dotnet@v5\n"
                "    with:\n"
                f"      dotnet-version: '{sdk}'\n",
                encoding="utf-8",
            )
        return root

    def test_selects_highest_supported_stable_channel(self) -> None:
        release = MODULE.latest_dotnet_release(self.fixture())
        self.assertEqual((10, 0), release.channel)
        self.assertEqual("10.0.11", release.runtime)
        self.assertEqual("10.0.400", release.sdk)

    def test_newer_supported_stable_channel_wins(self) -> None:
        release = MODULE.latest_dotnet_release(
            metadata(
                channel("11.0", "11.0.1", "11.0.101", release_type="sts"),
                channel("10.0", "10.0.11", "10.0.400"),
            )
        )
        self.assertEqual("11.0", release.channel_text)

    def test_rejects_malformed_duplicate_and_oversized_metadata(self) -> None:
        fixtures = (
            b"{}",
            b"{",
            metadata(channel("ten", "10.0.11", "10.0.400")),
            metadata(channel("10.0", "10.0-preview", "10.0.400")),
        )
        for value in fixtures:
            with self.subTest(value=value[:40]):
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.latest_dotnet_release(value)
        duplicate = self.fixture().replace(
            b'"channel-version": "11.0",',
            b'"channel-version": "11.0", "channel-version": "11.0",',
        )
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_dotnet_release(duplicate)
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_dotnet_release(b"x" * (MODULE.MAX_REMOTE_BYTES + 1))
        expired = self.fixture().replace(b"2099-11-09", b"2000-11-09")
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_dotnet_release(expired)

    def test_rejects_inconsistent_supported_channel_metadata(self) -> None:
        variants = (
            channel("10.0", "9.0.11", "10.0.400"),
            channel("10.0", "10.0.11", "9.0.400"),
            {**channel("10.0", "10.0.11", "10.0.400"), "product": "not-dotnet"},
            {**channel("10.0", "10.0.11", "10.0.400"), "releases.json": "https://example.test/releases.json"},
            {**channel("10.0", "10.0.11", "10.0.400"), "eol-date": "unknown"},
        )
        for entry in variants:
            with self.subTest(entry=entry):
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.latest_dotnet_release(metadata(entry))

    def test_project_accepts_exact_sdk_tfms_and_workflows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            release = MODULE.verify_project(root, self.fixture())
            self.assertEqual("10.0.400", release.sdk)

    def test_project_rejects_stale_or_floating_global_sdk(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, sdk="10.0.302")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            (root / "global.json").write_text(
                json.dumps(
                    {
                        "sdk": {
                            "version": "10.0.400",
                            "rollForward": "latestFeature",
                            "allowPrerelease": False,
                        }
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_project_rejects_stale_target_framework(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            path = root / "platform/windows/src/XanhBrowser.Core/XanhBrowser.Core.csproj"
            path.write_text(
                "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup>"
                "<TargetFramework>net8.0</TargetFramework>"
                "</PropertyGroup></Project>",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_project_rejects_plural_conditional_or_imported_frameworks(self) -> None:
        variants = (
            "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup>"
            "<TargetFramework>net10.0</TargetFramework>"
            "<TargetFrameworks>net8.0;net9.0</TargetFrameworks>"
            "</PropertyGroup></Project>",
            "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup "
            "Condition=\"'$(Configuration)' == 'Release'\">"
            "<TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>",
            "<Project Sdk=\"Microsoft.NET.Sdk\"><Import Project=\"framework.props\"/>"
            "<PropertyGroup>"
            "<TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>",
        )
        for contents in variants:
            with self.subTest(contents=contents):
                with tempfile.TemporaryDirectory() as directory:
                    root = self.project(directory)
                    path = (
                        root
                        / "platform/windows/src/XanhBrowser.Core/XanhBrowser.Core.csproj"
                    )
                    path.write_text(contents, encoding="utf-8")
                    with self.assertRaises(MODULE.VerificationError):
                        MODULE.verify_project(root, self.fixture())

    def test_project_rejects_shared_framework_override(self) -> None:
        variants = (
            "<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework>"
            "</PropertyGroup></Project>",
            "<Project Sdk=\"Example.Unreviewed.Sdk\"><PropertyGroup>"
            "<Nullable>enable</Nullable></PropertyGroup></Project>",
        )
        for contents in variants:
            with self.subTest(contents=contents):
                with tempfile.TemporaryDirectory() as directory:
                    root = self.project(directory)
                    props = root / "platform/windows/Directory.Build.props"
                    props.write_text(contents, encoding="utf-8")
                    with self.assertRaises(MODULE.VerificationError):
                        MODULE.verify_project(root, self.fixture())

    def test_project_rejects_ancestor_directory_build_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            (root / "Directory.Build.targets").write_text(
                "<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework>"
                "</PropertyGroup></Project>",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_project_rejects_stale_or_duplicate_workflow_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            workflow = root / ".github/workflows/windows.yml"
            workflow.write_text(
                "steps:\n  - uses: actions/setup-dotnet@v5\n    with:\n"
                "      dotnet-version: '10.0.x'\n",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            workflow.write_text(
                "steps:\n  - uses: actions/setup-dotnet@v5\n    with:\n"
                "      dotnet-version: '10.0.400'\n"
                "      dotnet-version: '10.0.400'\n",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            workflow.write_text(
                "steps:\n  - uses: actions/setup-dotnet@v5\n    with:\n"
                "      dotnet-version: '8.0.x'\n"
                "# dotnet-version: '10.0.400'\n",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            workflow.write_text(
                "steps:\n  - uses: actions/setup-dotnet@v5\n    with:\n"
                "      settings:\n"
                "        dotnet-version: '10.0.400'\n",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_project_rejects_dotnet_pin_from_unrelated_workflow_step(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            workflow = root / ".github/workflows/windows.yml"
            workflow.write_text(
                "steps:\n"
                "  - uses: actions/setup-dotnet@v5\n"
                "    with: { dotnet-version: '8.0.x' }\n"
                "  - uses: example/unrelated@v1\n"
                "    with:\n"
                "      dotnet-version: '10.0.400'\n",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_file_reader_rejects_symlink_and_oversize(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            oversized = root / "oversized"
            oversized.write_bytes(b"x" * (MODULE.MAX_REMOTE_BYTES + 1))
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(oversized, MODULE.MAX_REMOTE_BYTES)
            link = root / "link"
            os.symlink(oversized, link)
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(link, MODULE.MAX_REMOTE_BYTES)

    def test_fetch_requires_credential_free_https(self) -> None:
        for url in (
            "http://builds.dotnet.microsoft.com/releases-index.json",
            "https://user:secret@builds.dotnet.microsoft.com/releases-index.json",
        ):
            with self.assertRaises(MODULE.VerificationError):
                MODULE.fetch_official_metadata(url)


if __name__ == "__main__":
    unittest.main()
