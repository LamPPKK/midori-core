import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_androidx_webkit_latest.py"
SPEC = importlib.util.spec_from_file_location("verify_androidx_webkit_latest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def metadata(*versions: str, group: str = "androidx.webkit", artifact: str = "webkit") -> bytes:
    entries = "".join(f"<version>{version}</version>" for version in versions)
    return (
        "<?xml version='1.0' encoding='UTF-8'?>"
        f"<metadata><groupId>{group}</groupId><artifactId>{artifact}</artifactId>"
        f"<versioning><versions>{entries}</versions></versioning></metadata>"
    ).encode()


def verification_metadata(version: str, checksum: str = "a" * 64) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<verification-metadata xmlns="https://schema.gradle.org/dependency-verification">
  <components>
    <component group="androidx.webkit" name="webkit" version="{version}">
      <artifact name="webkit-{version}.aar"><sha256 value="{checksum}"/></artifact>
      <artifact name="webkit-{version}.module"><sha256 value="{'b' * 64}"/></artifact>
    </component>
  </components>
</verification-metadata>
"""


class AndroidXWebKitLatestTests(unittest.TestCase):
    def fixture(self) -> bytes:
        return metadata(
            "1.16.0",
            "1.17.0-alpha04",
            "1.17.0-rc01",
            "1.17.0",
        )

    def project(self, directory: str, version: str = "1.17.0", verify: bool = False) -> Path:
        root = Path(directory)
        (root / "app").mkdir(parents=True)
        (root / "app/build.gradle").write_text(
            f'dependencies {{ implementation "androidx.webkit:webkit:{version}" }}\n',
            encoding="utf-8",
        )
        if verify:
            (root / "gradle").mkdir()
            (root / "gradle/verification-metadata.xml").write_text(
                verification_metadata(version), encoding="utf-8"
            )
        return root

    def test_selects_latest_stable_and_ignores_prereleases(self) -> None:
        release = MODULE.latest_stable_release(self.fixture())
        self.assertEqual((1, 17, 0), release.version)
        self.assertEqual("1.17.0", release.text)

    def test_new_stable_release_wins(self) -> None:
        release = MODULE.latest_stable_release(
            metadata("1.17.1", "1.18.0-alpha01", "1.18.0")
        )
        self.assertEqual("1.18.0", release.text)

    def test_rejects_wrong_coordinates_duplicate_and_missing_stable(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(metadata("1.17.0", group="not.androidx"))
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(metadata("1.17.0", "1.17.0"))
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(metadata("1.18.0-alpha01"))

    def test_rejects_malformed_dtd_and_oversized_metadata(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(b"<metadata>")
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(b"<!DOCTYPE metadata><metadata/>")
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(
                b"<metadata><groupId>androidx.webkit</groupId>"
                b"<artifactId>webkit</artifactId><versioning><versions>"
                b"<version><value>1.17.0</value></version>"
                b"</versions></versioning></metadata>"
            )
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(b"x" * (MODULE.MAX_METADATA_BYTES + 1))

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "maven-metadata.xml"
            path.write_bytes(b"x" * (MODULE.MAX_METADATA_BYTES + 1))
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(path, MODULE.MAX_METADATA_BYTES)

    def test_project_requires_every_pin_to_match_latest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            (root / "feature").mkdir()
            (root / "feature/build.gradle.kts").write_text(
                'implementation("androidx.webkit:webkit:1.17.0")\n', encoding="utf-8"
            )
            release = MODULE.verify_project(root, self.fixture())
            self.assertEqual("1.17.0", release.text)
            (root / "feature/build.gradle.kts").write_text(
                'implementation("androidx.webkit:webkit:1.16.0")\n', encoding="utf-8"
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_project_rejects_dynamic_or_missing_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, "${webkitVersion}")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            (root / "app/build.gradle").write_text("dependencies {}\n", encoding="utf-8")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_strict_gradle_checksums_must_match_latest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, verify=True)
            MODULE.verify_project(root, self.fixture())
            (root / "gradle/verification-metadata.xml").write_text(
                verification_metadata("1.16.0"), encoding="utf-8"
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_rejects_invalid_gradle_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, verify=True)
            (root / "gradle/verification-metadata.xml").write_text(
                verification_metadata("1.17.0", "not-a-sha"), encoding="utf-8"
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

            duplicate = verification_metadata("1.17.0").replace(
                "</component>",
                '<artifact name="webkit-1.17.0.aar"><sha256 value="'
                + "c" * 64
                + '"/></artifact></component>',
            )
            (root / "gradle/verification-metadata.xml").write_text(
                duplicate, encoding="utf-8"
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_fetch_requires_credential_free_https(self) -> None:
        for url in (
            "http://dl.google.com/metadata.xml",
            "https://user:secret@dl.google.com/metadata.xml",
        ):
            with self.assertRaises(MODULE.VerificationError):
                MODULE.fetch_official_metadata(url)


if __name__ == "__main__":
    unittest.main()
