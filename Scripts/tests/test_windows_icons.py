"""Exercise generated Windows icons through compilation and publishing."""

from copy import deepcopy
import importlib.util
from pathlib import Path
import shutil
import struct
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "Scripts/generate-windows-icons.py"
PIL_AVAILABLE = importlib.util.find_spec("PIL") is not None


@unittest.skipUnless(PIL_AVAILABLE, "Install Scripts/build-requirements.txt")
class WindowsIconTests(unittest.TestCase):
    def run_command(self, *arguments):
        result = subprocess.run(arguments, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_clean_generation_validates_formats_and_repairs_incomplete_outputs(self):
        from PIL import Image

        with TemporaryDirectory() as directory:
            output = Path(directory) / "Generated Icons"
            self.run_command(sys.executable, str(GENERATOR), str(output))
            self.assertEqual(len(list(output.iterdir())), 25)
            for name, dimensions in {
                "StoreLogo": (50, 50), "Square44x44Logo": (44, 44),
                "Square150x150Logo": (150, 150), "Wide310x150Logo": (310, 150),
            }.items():
                for scale in (100, 125, 150, 200, 400):
                    with Image.open(output / f"{name}.scale-{scale}.png") as image:
                        self.assertEqual(image.size, tuple(value * scale // 100 for value in dimensions))
                self.assertEqual((output / f"{name}.png").read_bytes(),
                                 (output / f"{name}.scale-100.png").read_bytes())
            with Image.open(output / "FoldGit.ico") as image:
                self.assertEqual(image.ico.sizes(), {(size, size) for size in (16, 24, 32, 48, 64, 128, 256)})
            before = {path.name: path.stat().st_mtime_ns for path in output.iterdir()}
            self.run_command(sys.executable, str(GENERATOR), str(output))
            self.assertEqual(before, {path.name: path.stat().st_mtime_ns for path in output.iterdir()})
            self.run_command(sys.executable, str(GENERATOR), str(output), "--check")
            (output / "FoldGit.ico").write_bytes(b"incomplete")
            rejected = subprocess.run([sys.executable, str(GENERATOR), str(output), "--check"],
                                      capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.run_command(sys.executable, str(GENERATOR), str(output))
            self.run_command(sys.executable, str(GENERATOR), str(output), "--check")

    @unittest.skipUnless(shutil.which("dotnet"), ".NET SDK is required for MSBuild integration")
    def test_build_embeds_icon_and_copies_assets_to_build_and_publish_outputs(self):
        source = ET.parse(ROOT / "Platforms/Windows/src/FoldGit.App/FoldGit.App.csproj")
        generation = source.find("./Target[@Name='GenerateWindowsIcons']")
        self.assertIsNotNone(generation)
        sdk_version = self.run_command("dotnet", "--version").strip().split(".")[0]
        with TemporaryDirectory() as directory:
            work = Path(directory)
            project = ET.Element("Project", Sdk="Microsoft.NET.Sdk")
            properties = ET.SubElement(project, "PropertyGroup")
            for name, value in {"TargetFramework": f"net{sdk_version}.0", "OutputType": "Exe",
                                "UseAppHost": "false", "NuGetAudit": "false"}.items():
                ET.SubElement(properties, name).text = value
            inputs = ET.SubElement(project, "ItemGroup")
            ET.SubElement(inputs, "WindowsIconsInput", Include=str(GENERATOR))
            target = deepcopy(generation)
            for command in target.iter("Exec"):
                command.attrib["Command"] = command.attrib["Command"].replace(
                    "python ", f'"{sys.executable}" ', 1
                ).replace(
                    "$(MSBuildThisFileDirectory)..\\..\\..\\..\\Scripts\\generate-windows-icons.py",
                    str(GENERATOR),
                )
            project.append(target)
            report = ET.SubElement(project, "Target", Name="ReportIconBuild", AfterTargets="Build")
            ET.SubElement(report, "WriteLinesToFile", File="$(MSBuildThisFileDirectory)build-report.txt",
                          Lines="$(TargetDir);$(ApplicationIcon)", Overwrite="true")
            project_path = work / "IconProbe.csproj"
            ET.ElementTree(project).write(project_path, encoding="utf-8", xml_declaration=True)
            (work / "Program.cs").write_text("class Program { static void Main() {} }", encoding="utf-8")
            for architecture, packaging, configuration in (
                ("x64", "MSIX", "Debug"), ("ARM64", "MSIX", "Release"),
                ("x64", "None", "Release"), ("ARM64", "None", "Debug"),
            ):
                with self.subTest(architecture=architecture, packaging=packaging, configuration=configuration):
                    publish = work / "publish" / f"{architecture}-{packaging}-{configuration}"
                    self.run_command("dotnet", "publish", str(project_path), "-nologo", "-v:quiet",
                                     "-c", configuration, f"-p:Platform={architecture}",
                                     f"-p:WindowsPackageType={packaging}", "-o", str(publish))
                    built, icon = (work / "build-report.txt").read_text(encoding="utf-8-sig").splitlines()
                    icon_path = work / icon.replace("\\", "/")
                    self.assertTrue(icon_path.is_file())
                    for output in (Path(built), publish):
                        self.run_command(sys.executable, str(GENERATOR), str(output / "Assets"), "--check")
                    assembly = (publish / "IconProbe.dll").read_bytes()
                    icon_bytes = icon_path.read_bytes()
                    count = struct.unpack_from("<H", icon_bytes, 4)[0]
                    for index in range(count):
                        size, offset = struct.unpack_from("<II", icon_bytes, 6 + 16 * index + 8)
                        self.assertIn(icon_bytes[offset:offset + size], assembly,
                                      "The compiled assembly lost an embedded icon image")


if __name__ == "__main__":
    unittest.main()
