import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_android_toolchain_latest.py"
SPEC = importlib.util.spec_from_file_location("verify_android_toolchain_latest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def agp_metadata(*versions: str, group: str = "com.android.tools.build") -> bytes:
    entries = "".join(f"<version>{version}</version>" for version in versions)
    return (
        "<?xml version='1.0' encoding='UTF-8'?>"
        f"<metadata><groupId>{group}</groupId><artifactId>gradle</artifactId>"
        f"<versioning><versions>{entries}</versions></versioning></metadata>"
    ).encode()


def gradle_metadata(
    version: str = "9.7.1",
    distribution_checksum: str = "a" * 64,
    wrapper_checksum: str = "b" * 64,
    **overrides: object,
) -> bytes:
    distribution_url = f"https://services.gradle.org/distributions/gradle-{version}-bin.zip"
    document: dict[str, object] = {
        "version": version,
        "current": True,
        "released": True,
        "final": True,
        "snapshot": False,
        "nightly": False,
        "activeRc": False,
        "broken": False,
        "publicationSlot": version,
        "downloadUrl": distribution_url,
        "checksumUrl": f"{distribution_url}.sha256",
        "wrapperChecksumUrl": (
            f"https://services.gradle.org/distributions/gradle-{version}-wrapper.jar.sha256"
        ),
        "checksum": distribution_checksum,
        "wrapperChecksum": wrapper_checksum,
    }
    document.update(overrides)
    return json.dumps(document).encode()


class AndroidToolchainLatestTests(unittest.TestCase):
    def project(
        self,
        directory: str,
        *,
        agp: str = "9.3.1",
        gradle: str = "9.7.1",
        wrapper_jar: bytes = b"official wrapper",
    ) -> tuple[Path, bytes]:
        root = Path(directory)
        (root / "gradle/wrapper").mkdir(parents=True)
        (root / "build.gradle").write_text(
            "plugins {\n"
            f"    id 'com.android.application' version '{agp}' apply false\n"
            f"    id 'com.android.library' version '{agp}' apply false\n"
            f"    id 'com.android.dynamic-feature' version '{agp}' apply false\n"
            "}\n",
            encoding="utf-8",
        )
        distribution_checksum = "a" * 64
        (root / "gradle/wrapper/gradle-wrapper.properties").write_text(
            "distributionBase=GRADLE_USER_HOME\n"
            f"distributionSha256Sum={distribution_checksum}\n"
            f"distributionUrl=https\\://services.gradle.org/distributions/gradle-{gradle}-bin.zip\n"
            "validateDistributionUrl=true\n",
            encoding="utf-8",
        )
        (root / "gradle/wrapper/gradle-wrapper.jar").write_bytes(wrapper_jar)
        gradlew = root / "gradlew"
        gradlew.write_text("#!/bin/sh\n", encoding="utf-8")
        gradlew.chmod(0o755)
        (root / "gradlew.bat").write_text("@echo off\r\n", encoding="utf-8")
        metadata = gradle_metadata(
            gradle,
            distribution_checksum,
            hashlib.sha256(wrapper_jar).hexdigest(),
        )
        return root, metadata

    def test_selects_latest_stable_agp_and_ignores_prereleases(self) -> None:
        release = MODULE.latest_agp_release(
            agp_metadata("9.3.0", "9.3.1", "9.4.0-alpha01", "9.4.0-rc01")
        )
        self.assertEqual((9, 3, 1), release.version)
        self.assertEqual("9.3.1", release.text)

    def test_agp_metadata_rejects_wrong_duplicate_and_unsafe_input(self) -> None:
        for metadata in (
            agp_metadata("9.3.1", group="not.android.tools"),
            agp_metadata("9.3.1", "9.3.1"),
            agp_metadata("9.4.0-alpha01"),
            b"<!DOCTYPE metadata><metadata/>",
            b"<metadata>",
        ):
            with self.subTest(metadata=metadata[:40]):
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.latest_agp_release(metadata)

    def test_parses_exact_current_gradle_release(self) -> None:
        release = MODULE.current_gradle_release(gradle_metadata())
        self.assertEqual((9, 7, 1), release.version)
        self.assertEqual("9.7.1", release.text)
        self.assertEqual("a" * 64, release.distribution_checksum)
        self.assertEqual("b" * 64, release.wrapper_checksum)

    def test_gradle_metadata_rejects_prerelease_flags_and_wrong_urls(self) -> None:
        fixtures = (
            gradle_metadata("9.8.0-rc-1"),
            gradle_metadata(current=False),
            gradle_metadata(snapshot=True),
            gradle_metadata(downloadUrl="https://example.test/gradle.zip"),
            gradle_metadata(checksum="not-a-sha"),
        )
        for metadata in fixtures:
            with self.subTest(metadata=metadata):
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.current_gradle_release(metadata)

    def test_gradle_metadata_rejects_duplicate_keys_and_oversize(self) -> None:
        duplicate = gradle_metadata().replace(b'{"version": "9.7.1",', b'{"version": "9.7.1", "version": "9.7.0",')
        with self.assertRaises(MODULE.VerificationError):
            MODULE.current_gradle_release(duplicate)
        with self.assertRaises(MODULE.VerificationError):
            MODULE.current_gradle_release(b"x" * (MODULE.MAX_REMOTE_BYTES + 1))

    def test_project_accepts_exact_plugins_distribution_and_wrapper(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, gradle = self.project(directory)
            agp, release = MODULE.verify_project(
                root,
                agp_metadata("9.3.1", "9.4.0-alpha01"),
                gradle,
            )
            self.assertEqual("9.3.1", agp.text)
            self.assertEqual("9.7.1", release.text)

    def test_project_rejects_stale_or_duplicate_plugin_pins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, gradle = self.project(directory, agp="9.3.0")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, agp_metadata("9.3.1"), gradle)
            (root / "build.gradle").write_text(
                "plugins { id 'com.android.application' version '9.3.1' apply false }\n",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, agp_metadata("9.3.1"), gradle)

    def test_project_rejects_stale_distribution_and_wrapper_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, gradle = self.project(directory)
            properties = root / "gradle/wrapper/gradle-wrapper.properties"
            properties.write_text(
                properties.read_text(encoding="utf-8").replace("gradle-9.7.1", "gradle-9.7.0"),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, agp_metadata("9.3.1"), gradle)
            properties.write_text(
                properties.read_text(encoding="utf-8").replace("gradle-9.7.0", "gradle-9.7.1"),
                encoding="utf-8",
            )
            (root / "gradle/wrapper/gradle-wrapper.jar").write_bytes(b"tampered")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, agp_metadata("9.3.1"), gradle)

    def test_project_requires_executable_non_symlink_wrapper_scripts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, gradle = self.project(directory)
            (root / "gradlew").chmod(0o644)
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, agp_metadata("9.3.1"), gradle)
            (root / "gradlew").chmod(0o755)
            os.unlink(root / "gradlew.bat")
            os.symlink("gradlew", root / "gradlew.bat")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, agp_metadata("9.3.1"), gradle)

    def test_metadata_file_reader_rejects_symlink_and_oversize(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            oversized = root / "oversized"
            oversized.write_bytes(b"x" * (MODULE.MAX_REMOTE_BYTES + 1))
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(oversized, MODULE.MAX_REMOTE_BYTES)
            link = root / "link"
            link.symlink_to(oversized)
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(link, MODULE.MAX_REMOTE_BYTES)


if __name__ == "__main__":
    unittest.main()
