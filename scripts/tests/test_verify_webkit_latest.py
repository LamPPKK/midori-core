import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_webkit_latest.py"
SPEC = importlib.util.spec_from_file_location("verify_webkit_latest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def tag(revision: str, version: str, peeled: bool = False) -> str:
    suffix = "^{}" if peeled else ""
    return f"{revision}\trefs/tags/webkitgtk-{version}{suffix}\n"


class LatestStableReleaseTests(unittest.TestCase):
    old_revision = "1" * 40
    current_tag_revision = "2" * 40
    current_revision = "3" * 40
    development_revision = "4" * 40

    def fixture(self) -> str:
        return "".join(
            [
                tag(self.old_revision, "2.50.9", True),
                tag(self.current_tag_revision, "2.52.6"),
                tag(self.current_revision, "2.52.6", True),
                tag(self.development_revision, "2.53.90", True),
            ]
        )

    def test_selects_latest_even_minor_stable_and_peeled_revision(self) -> None:
        release = MODULE.latest_stable_release(self.fixture())
        self.assertEqual((2, 52, 6), release.version)
        self.assertEqual("webkitgtk-2.52.6", release.tag)
        self.assertEqual(self.current_revision, release.revision)

    def test_new_stable_series_wins(self) -> None:
        release = MODULE.latest_stable_release(
            self.fixture() + tag("5" * 40, "2.54.0", True)
        )
        self.assertEqual((2, 54, 0), release.version)

    def test_lightweight_stable_tag_uses_direct_revision(self) -> None:
        release = MODULE.latest_stable_release(tag(self.current_revision, "2.52.6"))
        self.assertEqual(self.current_revision, release.revision)

    def test_rejects_conflicting_duplicate_revision(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(
                tag(self.current_revision, "2.52.6", True)
                + tag(self.old_revision, "2.52.6", True)
            )

    def test_rejects_malformed_remote_output(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release("not-a-git-ls-remote-line\n")

    def test_rejects_missing_stable_tags(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(tag(self.development_revision, "2.53.90", True))

    def test_project_pin_must_equal_latest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "platform/windows-webkit").mkdir(parents=True)
            (root / "WEBKITGTK_MIN_VERSION").write_text("2.52.6\n", encoding="utf-8")
            (root / "platform/windows-webkit/WEBKIT_RELEASE_TAG").write_text(
                "webkitgtk-2.52.6\n", encoding="utf-8"
            )
            (root / "platform/windows-webkit/WEBKIT_REVISION").write_text(
                f"{self.current_revision}\n", encoding="utf-8"
            )
            release = MODULE.verify_project(root, self.fixture())
            self.assertEqual(self.current_revision, release.revision)

            (root / "WEBKITGTK_MIN_VERSION").write_text("2.52.5\n", encoding="utf-8")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

            (root / "WEBKITGTK_MIN_VERSION").write_text("2.52.6\n", encoding="utf-8")
            (root / "platform/windows-webkit/WEBKIT_RELEASE_TAG").write_text(
                "webkitgtk-2.52.5\n", encoding="utf-8"
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

            (root / "platform/windows-webkit/WEBKIT_RELEASE_TAG").write_text(
                "webkitgtk-2.52.6\n", encoding="utf-8"
            )
            (root / "platform/windows-webkit/WEBKIT_REVISION").write_text(
                f"{self.old_revision}\n", encoding="utf-8"
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_rejects_oversized_tag_list(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release("x" * (MODULE.MAX_TAG_LIST_BYTES + 1))


if __name__ == "__main__":
    unittest.main()
