import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_application_services_latest.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_application_services_latest", SCRIPT
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def tag(revision: str, version: str, peeled: bool = False) -> str:
    suffix = "^{}" if peeled else ""
    return f"{revision}\trefs/tags/v{version}{suffix}\n"


class ApplicationServicesLatestTests(unittest.TestCase):
    old_revision = "1" * 40
    tag_object = "2" * 40
    current_revision = "3" * 40

    def fixture(self) -> str:
        return "".join(
            [
                tag(self.old_revision, "154.0"),
                tag("4" * 40, "155.0-alpha.1"),
                tag(self.tag_object, "155.0"),
                tag(self.current_revision, "155.0", True),
            ]
        )

    def project(self, directory: str) -> Path:
        root = Path(directory)
        core = root / "xanh-sync-core"
        (core / "src").mkdir(parents=True)
        (core / "APPLICATION_SERVICES.lock").write_text(
            "version=155.0\n"
            "tag=v155.0\n"
            f"revision={self.current_revision}\n"
            "release_date=2026-08-13\n"
            "license=MPL-2.0\n"
            "maven_repository=https://maven.mozilla.org/maven2\n"
            "source=https://github.com/mozilla/application-services\n",
            encoding="utf-8",
        )
        dependencies = [
            "fxa-client",
            "init_rust_components",
            "logins",
            "places",
            "sync_manager",
            "tabs",
            "mozbuild",
        ]
        (core / "Cargo.toml").write_text(
            "\n".join(
                f'{name} = {{ git = "{MODULE.OFFICIAL_SOURCE}", '
                f'rev = "{self.current_revision}" }}'
                for name in dependencies
            )
            + "\n",
            encoding="utf-8",
        )
        (core / "Cargo.lock").write_text(
            "[[package]]\n"
            'name = "places"\n'
            f'source = "git+{MODULE.OFFICIAL_SOURCE}?rev={self.current_revision}'
            f'#{self.current_revision}"\n',
            encoding="utf-8",
        )
        (core / "src/lib.rs").write_text(
            'pub const APPLICATION_SERVICES_VERSION: &str = "155.0";\n'
            f'pub const APPLICATION_SERVICES_REVISION: &str = "{self.current_revision}";\n',
            encoding="utf-8",
        )
        (root / "THIRD_PARTY_NOTICES.md").write_text(
            "## Mozilla Application Services 155.0\n\n"
            "Xanh can link Mozilla Application Services 155.0 at revision\n"
            f"`{self.current_revision}`.\n\n"
            "https://github.com/mozilla/application-services/releases/tag/v155.0\n",
            encoding="utf-8",
        )
        return root

    def test_selects_latest_stable_and_peeled_revision(self) -> None:
        release = MODULE.latest_stable_release(self.fixture())
        self.assertEqual((155, 0, 0), release.version)
        self.assertEqual("155.0", release.text)
        self.assertEqual("v155.0", release.tag)
        self.assertEqual(self.current_revision, release.revision)

    def test_new_stable_release_wins_and_prerelease_is_ignored(self) -> None:
        release = MODULE.latest_stable_release(
            self.fixture()
            + tag("5" * 40, "155.1-beta.1")
            + tag("6" * 40, "156.0")
        )
        self.assertEqual("156.0", release.text)

    def test_lightweight_tag_uses_direct_revision(self) -> None:
        release = MODULE.latest_stable_release(tag(self.current_revision, "155.0"))
        self.assertEqual(self.current_revision, release.revision)

    def test_rejects_malformed_conflicting_and_oversized_tag_lists(self) -> None:
        invalid = (
            "not-ls-remote\n",
            f"{'z' * 40}\trefs/tags/v155.0\n",
            tag(self.current_revision, "155.0") + tag(self.old_revision, "155.0"),
            tag(self.current_revision, "155.0")
            + tag(self.old_revision, "155.0.0"),
            "x" * (MODULE.MAX_TAG_LIST_BYTES + 1),
        )
        for value in invalid:
            with self.subTest(value=value[:80]):
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.latest_stable_release(value)

    def test_project_accepts_exact_latest_stable_closure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            release = MODULE.verify_project(self.project(directory), self.fixture())
            self.assertEqual("155.0", release.text)

    def test_project_rejects_a_newer_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(
                    root, self.fixture() + tag("6" * 40, "156.0")
                )

    def test_lock_rejects_duplicate_missing_or_noncanonical_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            lock = root / MODULE.LOCK_PATH
            original = lock.read_text(encoding="utf-8")
            mutations = (
                original + "version=155.0\n",
                original.replace("license=MPL-2.0\n", ""),
                original.replace("release_date=2026-08-13", "release_date=2026-8-13"),
                original.replace(MODULE.OFFICIAL_SOURCE, "https://example.test/source"),
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
                    root / "xanh-sync-core/Cargo.toml",
                    lambda value: value.replace(self.current_revision, self.old_revision, 1),
                ),
                (
                    root / "xanh-sync-core/Cargo.lock",
                    lambda value: value.replace(self.current_revision, self.old_revision, 1),
                ),
                (
                    root / "xanh-sync-core/src/lib.rs",
                    lambda value: value.replace('"155.0"', '"154.0"'),
                ),
                (
                    root / "THIRD_PARTY_NOTICES.md",
                    lambda value: value.replace("releases/tag/v155.0", "releases/tag/v154.0"),
                ),
            )
            for path, mutate in paths_and_mutations:
                original = path.read_text(encoding="utf-8")
                with self.subTest(path=path):
                    path.write_text(mutate(original), encoding="utf-8")
                    with self.assertRaises(MODULE.VerificationError):
                        MODULE.verify_project(root, self.fixture())
                    path.write_text(original, encoding="utf-8")

    def test_rejects_floating_or_unreviewed_component_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            manifest = root / "xanh-sync-core/Cargo.toml"
            original = manifest.read_text(encoding="utf-8")
            manifest.write_text(
                original.replace(
                    f'rev = "{self.current_revision}"', 'branch = "main"', 1
                ),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

            manifest.write_text(
                original + f'extra = {{ git = "{MODULE.OFFICIAL_SOURCE}", rev = "{self.current_revision}" }}\n',
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())


if __name__ == "__main__":
    unittest.main()
