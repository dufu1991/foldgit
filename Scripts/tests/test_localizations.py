"""Verify native resource generation from a clean build directory."""

import json
from copy import deepcopy
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
CATALOGS = ROOT / "Shared/Resources/Localization"


class LocalizationGenerationTests(unittest.TestCase):
    def generate(self, platform, directory):
        subprocess.run(
            [sys.executable, str(ROOT / "Scripts/generate-resources.py"), platform, str(directory)],
            check=True,
        )

    def test_macos_generates_each_language_and_plural_rules(self):
        with TemporaryDirectory() as directory:
            output = Path(directory) / "App Resources"
            self.generate("macos", output)
            for source in CATALOGS.glob("*.json"):
                with self.subTest(language=source.stem):
                    catalog = json.loads(source.read_text(encoding="utf-8"))
                    localization = output / f"{source.stem}.lproj"
                    strings = (localization / "Localizable.strings").read_text(encoding="utf-8")
                    translation = json.dumps(catalog["strings"]["Copy Path"], ensure_ascii=False)
                    self.assertIn(f'"Copy Path" = {translation};', strings)
                    self.assertEqual(
                        plistlib.loads((localization / "Localizable.stringsdict").read_bytes()),
                        catalog["plurals"],
                    )
            self.assertEqual(len(list(output.glob("*/*"))), 2 * len(list(CATALOGS.glob("*.json"))))

    def test_windows_generates_only_manifest_resources(self):
        with TemporaryDirectory() as directory:
            output = Path(directory) / "Manifest Resources"
            self.generate("windows", output)
            for source in CATALOGS.glob("*.json"):
                with self.subTest(language=source.stem):
                    catalog = json.loads(source.read_text(encoding="utf-8"))
                    resource = ET.parse(output / source.stem / "Resources.resw")
                    self.assertEqual(
                        [(item.attrib["name"], item.findtext("value")) for item in resource.findall("data")],
                        [("AppDescription", catalog["windows"]["Git Client"])],
                    )
            self.assertEqual(len(list(output.glob("*/*"))), len(list(CATALOGS.glob("*.json"))))

    @unittest.skipUnless(shutil.which("dotnet"), ".NET SDK is required for MSBuild integration")
    def test_windows_build_registers_each_language_for_both_package_types(self):
        source = ET.parse(ROOT / "Platforms/Windows/src/FoldGit.App/FoldGit.App.csproj")
        generation = source.find("./Target[@Name='GenerateManifestLocalizations']")
        self.assertIsNotNone(generation)
        with TemporaryDirectory() as directory:
            project = ET.Element("Project")
            properties = ET.SubElement(project, "PropertyGroup")
            ET.SubElement(properties, "IntermediateOutputPath").text = (
                "$(MSBuildThisFileDirectory)obj/$(WindowsPackageType)/"
            )
            target = deepcopy(generation)
            command = target.find("Exec")
            command.attrib["Command"] = command.attrib["Command"].replace(
                "python ", f'"{sys.executable}" ', 1
            ).replace(
                "$(MSBuildThisFileDirectory)..\\..\\..\\..\\Scripts\\generate-resources.py",
                str(ROOT / "Scripts/generate-resources.py"),
            )
            project.append(target)
            ET.SubElement(project, "Target", Name="BeforeGenerateProjectPriFile")
            verify = ET.SubElement(project, "Target", Name="Verify", DependsOnTargets="BeforeGenerateProjectPriFile")
            ET.SubElement(verify, "WriteLinesToFile", File="$(IntermediateOutputPath)items.txt",
                          Lines="@(PRIResource->'%(FullPath)|%(Link)')", Overwrite="true")
            project_path = Path(directory) / "verify.proj"
            ET.ElementTree(project).write(project_path, encoding="utf-8", xml_declaration=True)
            expected = {f"Strings/{path.stem}/Resources.resw" for path in CATALOGS.glob("*.json")}
            for packaging in ("MSIX", "None"):
                with self.subTest(packaging=packaging):
                    result = subprocess.run(
                        ["dotnet", "msbuild", str(project_path), "-nologo", "-v:quiet", "-target:Verify",
                         f"-property:WindowsPackageType={packaging}"],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    items = (Path(directory) / "obj" / packaging / "items.txt").read_text(
                        encoding="utf-8-sig"
                    ).splitlines()
                    self.assertEqual({line.split("|", 1)[1].replace("\\", "/") for line in items}, expected)
                    self.assertTrue(all(Path(line.split("|", 1)[0]).is_file() for line in items))

    def test_repeated_generation_preserves_unchanged_outputs(self):
        with TemporaryDirectory() as directory:
            output = Path(directory)
            self.generate("macos", output)
            before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in output.glob("*/*")}
            self.generate("macos", output)
            after = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in output.glob("*/*")}
            self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
