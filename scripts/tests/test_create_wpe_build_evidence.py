import importlib.util
import hashlib
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "create_wpe_build_evidence.py"
SPEC = importlib.util.spec_from_file_location("create_wpe_build_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WpeBuildEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary_directory.name)
        self.root = self.base / "root"
        self.source = self.base / "source"
        self.output = self.base / "evidence"
        (self.root / "app-webkit/wpe-fork/patches").mkdir(parents=True)
        (self.root / "app-webkit/WPEVIEW_VERSION").write_text("0.3.3\n", encoding="utf-8")
        (self.root / "app-webkit/wpe-fork/WPE_RUNTIME_VERSION").write_text(
            "2.52.6\n", encoding="utf-8"
        )
        (self.root / "WEBKITGTK_MIN_VERSION").write_text("2.52.6\n", encoding="utf-8")
        self.source.mkdir()
        self.run_git("init")
        self.run_git("config", "user.name", "Xanh Test")
        self.run_git("config", "user.email", "test@example.invalid")
        wpe_files = {
            "README.md": "# WPE Android\n",
            "LICENSE.md": "GNU LESSER GENERAL PUBLIC LICENSE\n",
            "gradle/wrapper/gradle-wrapper.properties": (
                "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.12-bin.zip\n"
            ),
            "gradle/libs.versions.toml": 'target-android-sdk = "35"\n',
            "tools/scripts/bootstrap.py": 'default_version = "2.50.6"\n',
            "wpeview/build.gradle": "alias libs.plugins.android.library\n",
        }
        for relative_path, contents in wpe_files.items():
            path = self.source / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        self.run_git("add", ".")
        self.run_git("commit", "-m", "fixture")
        self.revision = self.run_git("rev-parse", "HEAD")
        (self.source / "README.md").write_text("# WPE Android with Xanh delta\n", encoding="utf-8")
        (self.root / "app-webkit/wpe-fork/patches/xanh-isolated-bridge.patch").write_text(
            self.run_git("diff", "--binary", "HEAD") + "\n", encoding="utf-8"
        )
        (self.root / "app-webkit/wpe-fork/WPE_ANDROID_REVISION").write_text(
            f"{self.revision}\n", encoding="utf-8"
        )
        self.cerbero = self.source / "build/cerbero"
        (self.cerbero / "recipes").mkdir(parents=True)
        (self.cerbero / "config").mkdir()
        (self.cerbero / "packages").mkdir()
        (self.cerbero / "cerbero/commands").mkdir(parents=True)
        self.original_wpewebkit_checksum = MODULE.WPEWEBKIT_SOURCE_SHA256
        self.wpewebkit_source_payload = b"pinned WPE WebKit 2.52.6 source tarball"
        MODULE.WPEWEBKIT_SOURCE_SHA256 = hashlib.sha256(
            self.wpewebkit_source_payload
        ).hexdigest()
        (self.cerbero / "recipes/wpewebkit.recipe").write_text(
            "version = '2.51.93'\n"
            "tarball_checksum = 'old-checksum'\n",
            encoding="utf-8",
        )
        (self.cerbero / "config/android.config").write_text(
            "ldflags = \"-Wl,--undefined-version '\"\n",
            encoding="utf-8",
        )
        for package in ("wpewebkit.package", "wpewebkit-core.package"):
            (self.cerbero / f"packages/{package}").write_text(
                "version = '2.51.93'\n", encoding="utf-8"
            )
        (self.cerbero / "LICENSE.LGPL").write_text(
            "GNU LIBRARY GENERAL PUBLIC LICENSE\n", encoding="utf-8"
        )
        (self.cerbero / "setup.py").write_text("class extended_sdist:\n    pass\n", encoding="utf-8")
        (self.cerbero / "cerbero/commands/bundlesource.py").write_text(
            "class BundleSource:\n    pass\n", encoding="utf-8"
        )
        self.run_git_at(self.cerbero, "init")
        self.run_git_at(self.cerbero, "config", "user.name", "Xanh Test")
        self.run_git_at(self.cerbero, "config", "user.email", "test@example.invalid")
        self.run_git_at(self.cerbero, "add", ".")
        self.run_git_at(self.cerbero, "commit", "-m", "cerbero fixture")
        self.cerbero_revision = self.run_git_at(self.cerbero, "rev-parse", "HEAD")
        (self.root / "app-webkit/wpe-fork/CERBERO_REVISION").write_text(
            f"{self.cerbero_revision}\n", encoding="utf-8"
        )
        (self.cerbero / "recipes/wpewebkit.recipe").write_text(
            "version = '2.52.6'\n"
            f"tarball_checksum = '{MODULE.WPEWEBKIT_SOURCE_SHA256}'\n",
            encoding="utf-8",
        )
        (self.cerbero / "config/android.config").write_text(
            "ldflags = \"-Wl,--undefined-version -Wl,-z,max-page-size=16384 "
            "-Wl,-z,common-page-size=16384 '\"\n",
            encoding="utf-8",
        )
        for package in ("wpewebkit.package", "wpewebkit-core.package"):
            (self.cerbero / f"packages/{package}").write_text(
                "version = '2.52.6'\n", encoding="utf-8"
            )
        (self.root / "app-webkit/wpe-fork/patches/cerbero-wpewebkit-2.52.6.patch").write_text(
            self.run_git_at(self.cerbero, "diff", "--binary", "HEAD") + "\n",
            encoding="utf-8",
        )
        self.upstream_source = self.base / "upstream.tar.gz"
        self.run_git(
            "archive",
            "--format=tar.gz",
            f"--prefix=wpe-android-{self.revision}/",
            f"--output={self.upstream_source}",
            self.revision,
        )
        self.cerbero_source = self.base / "cerbero-upstream.tar.gz"
        self.run_git_at(
            self.cerbero,
            "archive",
            "--format=tar.gz",
            f"--prefix=cerbero-{self.cerbero_revision}/",
            f"--output={self.cerbero_source}",
            self.cerbero_revision,
        )
        self.corresponding_source = self.base / "corresponding.tar.gz"
        self.create_corresponding_source(self.corresponding_source)
        self.build_environment = self.write_support(
            "build-environment.txt",
            (
                "schema=io.github.lamppkk.xanhbrowser.wpe-build-environment.v1\n"
                f"wpe_android_revision={self.revision}\n"
                "wpe_runtime_version=2.52.6\n"
                "JDK=17\n"
            ).encode("utf-8"),
        )
        self.build_log = self.write_support("build.log", b"BUILD SUCCESSFUL\n")
        self.alignment_evidence = self.write_support(
            "alignment.txt", b"Verified 16 KiB ELF alignment for 2 native libraries\n"
        )

    def tearDown(self) -> None:
        MODULE.WPEWEBKIT_SOURCE_SHA256 = self.original_wpewebkit_checksum
        self.temporary_directory.cleanup()

    def run_git(self, *arguments: str) -> str:
        return self.run_git_at(self.source, *arguments)

    def run_git_at(self, directory: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(directory), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout.strip()

    def write_support(self, name: str, contents: bytes) -> Path:
        path = self.base / name
        path.write_bytes(contents)
        return path

    def create_corresponding_source(self, path: Path, source_payload: bytes | None = None) -> None:
        prefix = "cerbero-1.24.8"
        source_payload = source_payload or self.wpewebkit_source_payload
        files = {
            "LICENSE.LGPL": (self.cerbero / "LICENSE.LGPL").read_bytes(),
            "config/android.config": (self.cerbero / "config/android.config").read_bytes(),
            "packages/wpewebkit.package": (
                self.cerbero / "packages/wpewebkit.package"
            ).read_bytes(),
            "packages/wpewebkit-core.package": (
                self.cerbero / "packages/wpewebkit-core.package"
            ).read_bytes(),
            "recipes/wpewebkit.recipe": (
                self.cerbero / "recipes/wpewebkit.recipe"
            ).read_bytes(),
            "sources/wpewebkit-2.52.6/wpewebkit-2.52.6.tar.xz": (
                source_payload
            ),
        }
        with tarfile.open(path, "w:gz") as archive:
            for relative_path, contents in files.items():
                info = tarfile.TarInfo(f"{prefix}/{relative_path}")
                info.size = len(contents)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(contents))

    def create_aar(self, entries: dict[str, bytes], name: str = "wpeview-release.aar") -> Path:
        path = self.base / name
        with zipfile.ZipFile(path, "w") as archive:
            for entry_name, contents in entries.items():
                archive.writestr(entry_name, contents)
        return path

    def valid_entries(self) -> dict[str, bytes]:
        return {
            "AndroidManifest.xml": b"manifest",
            "classes.jar": b"jar",
            "jni/arm64-v8a/libWPEWebKit-2.0.so": self.elf(183),
            "jni/x86_64/libWPEWebKit-2.0.so": self.elf(62),
        }

    def elf(self, machine: int, marker: bytes = b"wpewebkit-2.52.6") -> bytes:
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        header[18:20] = machine.to_bytes(2, "little")
        return bytes(header) + marker

    def create(self, aar: Path) -> Path:
        return MODULE.create_evidence(
            self.root,
            self.source,
            aar,
            self.upstream_source,
            self.cerbero_source,
            self.corresponding_source,
            self.build_environment,
            self.build_log,
            self.alignment_evidence,
            self.output,
        )

    def test_creates_provenance_checksum_and_complete_aar_sbom(self) -> None:
        evidence_path = self.create(self.create_aar(self.valid_entries()))
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        self.assertEqual(
            "io.github.lamppkk.xanhbrowser.wpe-build-evidence.v2", evidence["schema"]
        )
        self.assertEqual(["arm64-v8a", "x86_64"], evidence["artifact"]["architectures"])
        self.assertEqual(2, len(evidence["artifact"]["native_libraries"]))
        checksum_path = self.output / "xanh-wpeview-0.3.3-webkit-2.52.6.aar.sha256"
        self.assertIn(evidence["artifact"]["sha256"], checksum_path.read_text(encoding="utf-8"))
        sbom = json.loads((self.output / "wpeview-sbom.cdx.json").read_text(encoding="utf-8"))
        self.assertEqual("CycloneDX", sbom["bomFormat"])
        self.assertEqual(4, len(sbom["components"]))
        self.assertEqual(4, len(sbom["dependencies"][0]["dependsOn"]))
        self.assertEqual(evidence_path, MODULE.verify_evidence(self.root, self.output))

    def test_verifier_rejects_artifact_or_sbom_tampering(self) -> None:
        self.create(self.create_aar(self.valid_entries()))
        artifact = self.output / "xanh-wpeview-0.3.3-webkit-2.52.6.aar"
        artifact.write_bytes(artifact.read_bytes() + b"tampered")
        with self.assertRaises(MODULE.EvidenceError):
            MODULE.verify_evidence(self.root, self.output)

        self.output = self.base / "second-evidence"
        self.create(self.create_aar(self.valid_entries(), "second.aar"))
        sbom_path = self.output / "wpeview-sbom.cdx.json"
        sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
        sbom["components"] = []
        sbom_path.write_text(json.dumps(sbom), encoding="utf-8")
        with self.assertRaises(MODULE.EvidenceError):
            MODULE.verify_evidence(self.root, self.output)

    def test_rejects_missing_supported_abi(self) -> None:
        entries = self.valid_entries()
        del entries["jni/x86_64/libWPEWebKit-2.0.so"]
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(entries))

    def test_rejects_unsupported_abi(self) -> None:
        entries = self.valid_entries()
        entries["jni/armeabi-v7a/libunexpected.so"] = self.elf(40)
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(entries))

    def test_rejects_unclassified_native_library(self) -> None:
        entries = self.valid_entries()
        entries["assets/libunexpected.so"] = self.elf(62)
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(entries))

    def test_rejects_missing_runtime_marker_for_either_abi(self) -> None:
        entries = self.valid_entries()
        entries["jni/x86_64/libWPEWebKit-2.0.so"] = self.elf(62, b"wrong-runtime")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(entries))

    def test_rejects_elf_machine_that_does_not_match_abi_path(self) -> None:
        entries = self.valid_entries()
        entries["jni/arm64-v8a/libWPEWebKit-2.0.so"] = self.elf(62)
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(entries))

    def test_rejects_duplicate_or_unsafe_archive_paths(self) -> None:
        duplicate = self.base / "duplicate.aar"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(duplicate, "w") as archive:
                archive.writestr("AndroidManifest.xml", b"first")
                archive.writestr("AndroidManifest.xml", b"second")
                archive.writestr("classes.jar", b"jar")
                archive.writestr(
                    "jni/arm64-v8a/libWPEWebKit-2.0.so", self.elf(183)
                )
                archive.writestr(
                    "jni/x86_64/libWPEWebKit-2.0.so", self.elf(62)
                )
        with self.assertRaises(MODULE.EvidenceError):
            self.create(duplicate)

        unsafe = self.valid_entries()
        unsafe["../outside"] = b"unsafe"
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(unsafe, "unsafe.aar"))

        noncanonical = self.valid_entries()
        noncanonical["assets//duplicate-separator"] = b"unsafe"
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(noncanonical, "noncanonical.aar"))

    def test_rejects_entry_count_over_safety_bound(self) -> None:
        aar = self.create_aar(self.valid_entries())
        original = MODULE.MAX_AAR_ENTRIES
        MODULE.MAX_AAR_ENTRIES = 3
        try:
            with self.assertRaises(MODULE.EvidenceError):
                self.create(aar)
        finally:
            MODULE.MAX_AAR_ENTRIES = original

    def test_rejects_runtime_baseline_or_revision_mismatch(self) -> None:
        aar = self.create_aar(self.valid_entries())
        (self.root / "WEBKITGTK_MIN_VERSION").write_text("2.52.5\n", encoding="utf-8")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(aar)

        (self.root / "WEBKITGTK_MIN_VERSION").write_text("2.52.6\n", encoding="utf-8")
        (self.root / "app-webkit/wpe-fork/WPE_ANDROID_REVISION").write_text(
            f"{'d' * 40}\n", encoding="utf-8"
        )
        with self.assertRaises(MODULE.EvidenceError):
            self.create(aar)

    def test_refuses_to_overwrite_existing_output(self) -> None:
        self.output.mkdir()
        (self.output / "keep.txt").write_text("user data\n", encoding="utf-8")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(self.valid_entries()))
        self.assertEqual("user data\n", (self.output / "keep.txt").read_text(encoding="utf-8"))

    def test_rejects_source_checkout_without_reviewed_patch(self) -> None:
        self.run_git("checkout", "--", "README.md")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(self.valid_entries()))

    def test_rejects_extra_tracked_source_or_cerbero_delta(self) -> None:
        (self.source / "LICENSE.md").write_text("changed outside patch\n", encoding="utf-8")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(self.valid_entries()))

        self.run_git("checkout", "--", "LICENSE.md")
        (self.cerbero / "setup.py").write_text("unexpected change\n", encoding="utf-8")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(self.valid_entries(), "cerbero-drift.aar"))

    def test_rejects_staged_delta_outside_reviewed_patch(self) -> None:
        (self.source / "LICENSE.md").write_text("staged extra change\n", encoding="utf-8")
        self.run_git("add", "LICENSE.md")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(self.valid_entries()))

    def test_rejects_invalid_or_mutated_source_archives(self) -> None:
        self.upstream_source.write_bytes(b"not a tar archive")
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(self.valid_entries()))

        self.run_git(
            "archive",
            "--format=tar.gz",
            f"--prefix=wpe-android-{self.revision}/",
            f"--output={self.upstream_source}",
            self.revision,
        )
        self.create_corresponding_source(
            self.corresponding_source, source_payload=b"wrong WPE source"
        )
        with self.assertRaises(MODULE.EvidenceError):
            self.create(self.create_aar(self.valid_entries(), "source-drift.aar"))


if __name__ == "__main__":
    unittest.main()
