import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_adblock_latest.py"
SPEC = importlib.util.spec_from_file_location("verify_adblock_latest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def tag(revision: str, version: str, peeled: bool = False) -> str:
    suffix = "^{}" if peeled else ""
    return f"{revision}\trefs/tags/v{version}{suffix}\n"


class AdblockLatestTests(unittest.TestCase):
    old_revision = "1" * 40
    tag_object = "2" * 40
    current_revision = "3" * 40
    checksum = "4" * 64

    def fixture(self) -> str:
        return "".join(
            (
                tag(self.old_revision, "0.13.2"),
                tag("5" * 40, "0.13.3-beta.1"),
                tag(self.tag_object, "0.13.3"),
                tag(self.current_revision, "0.13.3", True),
                tag("6" * 40, "0.9.6-brave-core"),
            )
        )

    def project(self, directory: str) -> Path:
        root = Path(directory)
        core = root / "xanh-adblock-core"
        (core / "src").mkdir(parents=True)
        (core / "ADBLOCK_RUST.lock").write_text(
            "version=0.13.3\n"
            "tag=v0.13.3\n"
            f"revision={self.current_revision}\n"
            f"source={MODULE.OFFICIAL_SOURCE}\n"
            "license=MPL-2.0\n"
            f"crate_checksum={self.checksum}\n",
            encoding="utf-8",
        )
        (core / "Cargo.toml").write_text(
            "[package]\nname = \"xanh-adblock-core\"\nversion = \"1.0.0\"\n"
            "[dependencies]\n"
            "adblock = { version = \"=0.13.3\", default-features = false, "
            "features = [\"content-blocking\", \"embedded-domain-resolver\", "
            "\"full-regex-handling\"] }\n",
            encoding="utf-8",
        )
        (core / "Cargo.lock").write_text(
            "version = 4\n\n[[package]]\nname = \"adblock\"\n"
            "version = \"0.13.3\"\n"
            "source = \"registry+https://github.com/rust-lang/crates.io-index\"\n"
            f"checksum = \"{self.checksum}\"\n",
            encoding="utf-8",
        )
        (core / "src/lib.rs").write_text(
            'pub const ADBLOCK_RUST_VERSION: &str = "0.13.3";\n'
            f'pub const ADBLOCK_RUST_REVISION: &str = "{self.current_revision}";\n',
            encoding="utf-8",
        )
        (root / "THIRD_PARTY_NOTICES.md").write_text(
            "## Brave adblock-rust 0.13.3\n\n"
            f"Revision `{self.current_revision}`.\n"
            "https://github.com/brave/adblock-rust/releases/tag/v0.13.3\n"
            f"Crate SHA-256 `{self.checksum}`.\n",
            encoding="utf-8",
        )
        return root

    def test_selects_latest_stable_and_prefers_peeled_revision(self) -> None:
        release = MODULE.latest_stable_release(self.fixture())
        self.assertEqual((0, 13, 3), release.version)
        self.assertEqual("v0.13.3", release.tag)
        self.assertEqual(self.current_revision, release.revision)

    def test_new_stable_wins_and_prereleases_are_ignored(self) -> None:
        release = MODULE.latest_stable_release(
            self.fixture() + tag("7" * 40, "0.14.0-rc.1") + tag("8" * 40, "0.14.0")
        )
        self.assertEqual("0.14.0", release.text)

    def test_lightweight_tag_uses_direct_revision(self) -> None:
        release = MODULE.latest_stable_release(tag(self.current_revision, "0.13.3"))
        self.assertEqual(self.current_revision, release.revision)

    def test_rejects_malformed_conflicting_and_oversized_tag_lists(self) -> None:
        invalid = (
            "not-ls-remote\n",
            f"{'z' * 40}\trefs/tags/v0.13.3\n",
            tag(self.current_revision, "0.13.3")
            + tag(self.old_revision, "0.13.3"),
            "x" * (MODULE.MAX_TAG_LIST_BYTES + 1),
        )
        for value in invalid:
            with self.subTest(value=value[:80]):
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.latest_stable_release(value)

    def test_project_accepts_exact_latest_stable_closure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            release = MODULE.verify_project(self.project(directory), self.fixture())
            self.assertEqual("0.13.3", release.text)

    def test_project_rejects_new_release_or_wrong_revision(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(
                    root, self.fixture() + tag("8" * 40, "0.14.0")
                )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(
                    root,
                    self.fixture().replace(self.current_revision, self.old_revision),
                )

    def test_lock_rejects_duplicate_missing_or_unofficial_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            lock = root / MODULE.LOCK_PATH
            original = lock.read_text(encoding="utf-8")
            mutations = (
                original + "version=0.13.3\n",
                original.replace("license=MPL-2.0\n", ""),
                original.replace(MODULE.OFFICIAL_SOURCE, "https://example.test/source"),
                original.replace(self.checksum, "not-a-checksum"),
            )
            for value in mutations:
                with self.subTest(value=value):
                    lock.write_text(value, encoding="utf-8")
                    with self.assertRaises(MODULE.VerificationError):
                        MODULE.verify_project(root, self.fixture())
            lock.write_text(original, encoding="utf-8")

    def test_rejects_manifest_lock_constant_and_notice_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            paths_and_mutations = (
                (
                    root / "xanh-adblock-core/Cargo.toml",
                    lambda value: value.replace("=0.13.3", "^0.13"),
                ),
                (
                    root / "xanh-adblock-core/Cargo.toml",
                    lambda value: value.replace("default-features = false", "default-features = true"),
                ),
                (
                    root / "xanh-adblock-core/Cargo.lock",
                    lambda value: value.replace(self.checksum, "5" * 64),
                ),
                (
                    root / "xanh-adblock-core/src/lib.rs",
                    lambda value: value.replace('"0.13.3"', '"0.13.2"'),
                ),
                (
                    root / "THIRD_PARTY_NOTICES.md",
                    lambda value: value.replace("releases/tag/v0.13.3", "releases/tag/v0.13.2"),
                ),
            )
            for path, mutation in paths_and_mutations:
                original = path.read_text(encoding="utf-8")
                with self.subTest(path=path, mutation=mutation(original)):
                    path.write_text(mutation(original), encoding="utf-8")
                    with self.assertRaises(MODULE.VerificationError):
                        MODULE.verify_project(root, self.fixture())
                    path.write_text(original, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
