import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_webview2_latest.py"
SPEC = importlib.util.spec_from_file_location("verify_webview2_latest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def index(*versions: object) -> bytes:
    return json.dumps({"versions": list(versions)}, separators=(",", ":")).encode()


def project_xml(version: str | None, central: bool = False) -> str:
    if central:
        return (
            '<Project><ItemGroup><PackageVersion Include="Microsoft.Web.WebView2" '
            f'Version="{version}" /></ItemGroup></Project>'
        )
    version_attribute = "" if version is None else f' Version="{version}"'
    return (
        '<Project><ItemGroup><PackageReference Include="Microsoft.Web.WebView2"'
        f"{version_attribute} /></ItemGroup></Project>"
    )


class WebView2LatestTests(unittest.TestCase):
    def fixture(self) -> bytes:
        return index(
            "1.0.4078.44",
            "1.0.4126-prerelease",
            "1.0.4129.50",
            "1.0.4181-prerelease",
        )

    def project(self, directory: str, version: str | None = "1.0.4129.50") -> Path:
        root = Path(directory)
        target = root / "platform/windows/src/XanhBrowser.Windows"
        target.mkdir(parents=True)
        (target / "XanhBrowser.Windows.csproj").write_text(
            project_xml(version), encoding="utf-8"
        )
        return root

    def test_selects_latest_stable_and_ignores_prereleases(self) -> None:
        release = MODULE.latest_stable_release(self.fixture())
        self.assertEqual((1, 0, 4129, 50), release.version)
        self.assertEqual("1.0.4129.50", release.text)

    def test_new_stable_release_wins(self) -> None:
        release = MODULE.latest_stable_release(
            index("1.0.4129.50", "1.0.4181-prerelease", "1.0.4184.10")
        )
        self.assertEqual("1.0.4184.10", release.text)

    def test_rejects_duplicate_key_version_and_missing_stable(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(b'{"versions":[],"versions":[]}')
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(index("1.0.4129.50", "1.0.4129.50"))
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(index("1.0.4181-prerelease"))

    def test_rejects_malformed_structured_and_oversized_index(self) -> None:
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(b'{"versions":')
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(index({"version": "1.0.4129.50"}))
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(
                b'{"versions":[' + b"9" * 5000 + b"]}"
            )
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(b"x" * (MODULE.MAX_INDEX_BYTES + 1))

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "index.json"
            path.write_bytes(b"x" * (MODULE.MAX_INDEX_BYTES + 1))
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(path, MODULE.MAX_INDEX_BYTES)

    def test_project_requires_every_pin_to_match_latest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            release = MODULE.verify_project(root, self.fixture())
            self.assertEqual("1.0.4129.50", release.text)
            csproj = root / "platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj"
            csproj.write_text(project_xml("1.0.4078.44"), encoding="utf-8")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_project_rejects_dynamic_missing_and_unsafe_xml(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, "$(WebView2Version)")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            csproj = root / "platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj"
            csproj.write_text(project_xml(None), encoding="utf-8")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            csproj.write_text("<!DOCTYPE Project><Project/>", encoding="utf-8")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())
            csproj.write_text(
                '<NotProject><PackageReference Include="Microsoft.Web.WebView2" '
                'Version="1.0.4129.50" /></NotProject>',
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_central_pin_can_version_an_unversioned_reference(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, None)
            (root / "Directory.Packages.props").write_text(
                project_xml("1.0.4129.50", central=True), encoding="utf-8"
            )
            release = MODULE.verify_project(root, self.fixture())
            self.assertEqual("1.0.4129.50", release.text)

    def test_rejects_conflicting_attribute_and_child_versions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            csproj = root / "platform/windows/src/XanhBrowser.Windows/XanhBrowser.Windows.csproj"
            csproj.write_text(
                '<Project><ItemGroup><PackageReference Include="Microsoft.Web.WebView2" '
                'Version="1.0.4129.50"><Version>1.0.4129.50</Version>'
                "</PackageReference></ItemGroup></Project>",
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, self.fixture())

    def test_fetch_requires_credential_free_https(self) -> None:
        for url in (
            "http://api.nuget.org/index.json",
            "https://user:secret@api.nuget.org/index.json",
        ):
            with self.assertRaises(MODULE.VerificationError):
                MODULE.fetch_official_index(url)


if __name__ == "__main__":
    unittest.main()
