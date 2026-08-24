import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_android_ui_latest.py"
SPEC = importlib.util.spec_from_file_location("verify_android_ui_latest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


VERSIONS = {
    "activity": "1.13.0",
    "annotation": "1.10.0",
    "appcompat": "1.8.0",
    "browser": "1.10.0",
    "material": "1.14.0",
    "feature_delivery": "2.1.0",
    "biometric": "1.1.0",
    "core": "1.19.0",
    "lifecycle_runtime": "2.11.0",
    "lifecycle_process": "2.11.0",
    "recyclerview": "1.4.0",
    "room_runtime": "2.8.4",
    "room_ktx": "2.8.4",
    "room_compiler": "2.8.4",
    "room_testing": "2.8.4",
    "work": "2.11.2",
    "androidx_test_junit": "1.3.0",
    "espresso": "3.7.0",
    "test_runner": "1.7.0",
    "junit4": "4.13.2",
    "json": "20260814",
    "ksp": "2.3.11",
}


def metadata(key: str, *versions: str, group: str | None = None) -> bytes:
    spec = MODULE.SPECS_BY_KEY[key]
    entries = "".join(f"<version>{version}</version>" for version in versions)
    return (
        "<?xml version='1.0' encoding='UTF-8'?>"
        f"<metadata><groupId>{group or spec.group}</groupId>"
        f"<artifactId>{spec.artifact}</artifactId>"
        f"<versioning><versions>{entries}</versions></versioning></metadata>"
    ).encode()


def metadata_set(
    include_ksp: bool = False, extra_keys: tuple[str, ...] = ()
) -> dict[str, bytes]:
    keys = [spec.key for spec in MODULE.UI_SPECS] + list(extra_keys)
    if include_ksp:
        keys.append("ksp")
    return {
        key: metadata(key, "0.1.0", f"{VERSIONS[key]}-rc01", VERSIONS[key])
        for key in keys
    }


def verification_metadata(
    include_ksp: bool = False,
    bad_hash: bool = False,
    extra_keys: tuple[str, ...] = (),
) -> str:
    keys = [spec.key for spec in MODULE.UI_SPECS] + list(extra_keys)
    if include_ksp:
        keys.append("ksp")
    components: list[str] = []
    checksum_index = 0
    for key in keys:
        version = VERSIONS[key]
        for requirement in MODULE.SPECS_BY_KEY[key].checksums:
            artifacts: list[str] = []
            for extension in requirement.extensions:
                checksum_index += 1
                checksum = "bad" if bad_hash and checksum_index == 1 else f"{checksum_index:064x}"
                name = f"{requirement.name}-{version}.{extension}"
                artifacts.append(
                    f'<artifact name="{name}"><sha256 value="{checksum}"/></artifact>'
                )
            components.append(
                f'<component group="{requirement.group}" name="{requirement.name}" '
                f'version="{version}">{"".join(artifacts)}</component>'
            )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<verification-metadata xmlns="https://schema.gradle.org/dependency-verification">'
        f'<components>{"".join(components)}</components></verification-metadata>'
    )


class AndroidUILatestTests(unittest.TestCase):
    def project(
        self,
        directory: str,
        *,
        include_ksp: bool = False,
        strict: bool = False,
        extra_keys: tuple[str, ...] = (),
    ) -> Path:
        root = Path(directory)
        (root / "app").mkdir(parents=True)
        lines = [
            f'implementation "{spec.group}:{spec.artifact}:{VERSIONS[spec.key]}"'
            for spec in (*MODULE.UI_SPECS, *(MODULE.SPECS_BY_KEY[key] for key in extra_keys))
        ]
        (root / "app/build.gradle").write_text("\n".join(lines) + "\n", encoding="utf-8")
        if include_ksp:
            (root / "build.gradle").write_text(
                f"plugins {{ id '{MODULE.KSP_PLUGIN_ID}' version '{VERSIONS['ksp']}' apply false }}\n",
                encoding="utf-8",
            )
        if strict:
            (root / "gradle").mkdir()
            (root / "gradle/verification-metadata.xml").write_text(
                verification_metadata(include_ksp, extra_keys=extra_keys), encoding="utf-8"
            )
        return root

    def test_selects_latest_stable_and_ignores_prereleases(self) -> None:
        for spec in MODULE.SPECS_BY_KEY.values():
            release = MODULE.latest_stable_release(
                metadata(spec.key, "1.0.0", "9.0.0-alpha01", VERSIONS[spec.key]), spec
            )
            self.assertEqual(VERSIONS[spec.key], release.text)

    def test_rejects_wrong_coordinates_duplicate_and_missing_stable(self) -> None:
        spec = MODULE.UI_SPECS[0]
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(metadata(spec.key, "1.13.0", group="wrong"), spec)
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(metadata(spec.key, "1.13.0", "1.13.0"), spec)
        with self.assertRaises(MODULE.VerificationError):
            MODULE.latest_stable_release(metadata(spec.key, "1.14.0-beta01"), spec)

    def test_rejects_malformed_dtd_structured_and_oversized_metadata(self) -> None:
        spec = MODULE.UI_SPECS[0]
        for contents in (
            b"<metadata>",
            b"<!DOCTYPE metadata><metadata/>",
            metadata(spec.key, "1.13.0").replace(
                b"<version>1.13.0</version>", b"<version><value>1.13.0</value></version>"
            ),
            b"x" * (MODULE.MAX_METADATA_BYTES + 1),
        ):
            with self.assertRaises(MODULE.VerificationError):
                MODULE.latest_stable_release(contents, spec)

    def test_project_requires_every_ui_pin_to_match_latest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            releases = MODULE.verify_project(root, metadata_set())
            self.assertEqual(VERSIONS["material"], releases["material"].text)
            path = root / "app/build.gradle"
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "androidx.browser:browser:1.10.0", "androidx.browser:browser:1.9.0"
                ),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, metadata_set())

    def test_project_rejects_dynamic_and_missing_ui_pins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            path = root / "app/build.gradle"
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "androidx.activity:activity-ktx:1.13.0",
                    "androidx.activity:activity-ktx:${activityVersion}",
                ),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, metadata_set())
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "androidx.annotation:annotation:1.10.0", ""
                ),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.project_dependency_pins(root)

    def test_ksp_is_optional_but_must_be_explicit_and_latest_when_applied(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            self.assertNotIn("ksp", MODULE.verify_project(root, metadata_set()))
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, include_ksp=True)
            self.assertEqual(
                VERSIONS["ksp"], MODULE.verify_project(root, metadata_set(True))["ksp"].text
            )
            (root / "build.gradle").write_text(
                f"plugins {{ id '{MODULE.KSP_PLUGIN_ID}' }}\n", encoding="utf-8"
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.project_dependency_pins(root)

    def test_optional_direct_dependencies_are_verified_when_present(self) -> None:
        extras = (
            "feature_delivery",
            "biometric",
            "core",
            "lifecycle_runtime",
            "recyclerview",
            "room_runtime",
            "room_compiler",
            "work",
            "androidx_test_junit",
            "espresso",
            "test_runner",
            "junit4",
            "json",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, extra_keys=extras)
            releases = MODULE.verify_project(root, metadata_set(extra_keys=extras))
            self.assertEqual(set(extras), set(releases) - {spec.key for spec in MODULE.UI_SPECS})
            path = root / "app/build.gradle"
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "androidx.room:room-runtime:2.8.4",
                    "androidx.room:room-runtime:2.8.3",
                ),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, metadata_set(extra_keys=extras))

    def test_untracked_dependency_fails_and_dedicated_families_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            path = root / "app/build.gradle"
            path.write_text(
                path.read_text(encoding="utf-8")
                + 'implementation "com.example:untracked:1.0.0"\n',
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.project_dependency_pins(root)
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            path = root / "app/build.gradle"
            path.write_text(
                path.read_text(encoding="utf-8")
                + 'implementation "androidx.webkit:webkit:1.17.0"\n'
                + 'implementation "org.mozilla.appservices:places:155.0"\n'
                + 'implementation "org.wpewebkit.wpeview:wpeview:${wpeVersion}"\n'
                + 'implementation "io.github.lamppkk.xanhbrowser:xanh-sync-android:1.0.0-alpha.1"\n',
                encoding="utf-8",
            )
            MODULE.project_dependency_pins(root)

    def test_strict_gradle_checksums_cover_every_required_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            extras = (
                "core",
                "lifecycle_runtime",
                "room_runtime",
                "test_runner",
                "junit4",
            )
            root = self.project(
                directory, include_ksp=True, strict=True, extra_keys=extras
            )
            MODULE.verify_project(root, metadata_set(True, extras))

    def test_rejects_invalid_or_missing_strict_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory, strict=True)
            metadata_path = root / "gradle/verification-metadata.xml"
            metadata_path.write_text(verification_metadata(bad_hash=True), encoding="utf-8")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, metadata_set())
            metadata_path.write_text(
                verification_metadata().replace("activity-ktx-1.13.0.aar", "wrong.aar"),
                encoding="utf-8",
            )
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, metadata_set())

    def test_metadata_set_must_exactly_match_project_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.project(directory)
            fixtures = metadata_set()
            fixtures.pop("browser")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, fixtures)
            fixtures = metadata_set()
            fixtures["ksp"] = metadata("ksp", VERSIONS["ksp"])
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_project(root, fixtures)

    def test_input_files_and_urls_are_bounded_and_credential_free(self) -> None:
        for url in ("http://example.test/a", "https://user:secret@example.test/a"):
            with self.assertRaises(MODULE.VerificationError):
                MODULE._validate_metadata_url(url)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metadata.xml"
            path.write_bytes(b"x" * (MODULE.MAX_METADATA_BYTES + 1))
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(path, MODULE.MAX_METADATA_BYTES)
            link = Path(directory) / "link.xml"
            link.symlink_to(path)
            with self.assertRaises(MODULE.VerificationError):
                MODULE._read_bounded_bytes(link, MODULE.MAX_METADATA_BYTES)


if __name__ == "__main__":
    unittest.main()
