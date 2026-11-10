"""Check that release packaging keeps only the Shiki themes FoldGit requests."""

import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/trim-shiki-themes.py"
SEPARATOR = "=" * 105


def notice_section(*files):
    return f"\nFiles:   {', '.join(files)}\nLicense: MIT\n{'-' * 105}\nCopyright {files[0]}\n\n"


class TrimShikiThemesTests(unittest.TestCase):
    def make_bundle(self, directory):
        resources = Path(directory) / "ShikiSwift_Shiki.bundle/Contents/Resources"
        (resources / "themes").mkdir(parents=True)
        (resources / "licenses").mkdir()
        names = ["dracula", "github-dark", "github-dark-dimmed", "github-light", "nord"]
        for name in names:
            (resources / f"themes/{name}.json").write_text("{}", encoding="utf-8")
        manifest = {
            "schemaVersion": 1,
            "themeNames": names,
            "themes": [{"id": name, "resource": f"themes/{name}.json", "type": "dark"} for name in names],
        }
        (resources / "theme-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        notice = SEPARATOR.join([
            "THIRD-PARTY SOFTWARE NOTICES\n",
            notice_section("dracula.json"),
            notice_section("github-dark.json", "github-dark-dimmed.json", "github-light.json"),
            notice_section("nord.json"),
        ])
        (resources / "licenses/tm-themes-NOTICE.txt").write_text(notice, encoding="utf-8")
        return resources

    def trim(self, resources, *arguments):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(resources.parents[1]), *arguments],
                              capture_output=True, text=True)

    def test_keeps_default_themes_with_matching_manifest_and_notices(self):
        with TemporaryDirectory() as directory:
            resources = self.make_bundle(directory)
            for _ in range(2):
                result = self.trim(resources)
                self.assertEqual(result.returncode, 0, result.stderr)
            files = sorted(path.name for path in (resources / "themes").iterdir())
            self.assertEqual(files, ["github-dark.json", "github-light.json"])
            manifest = json.loads((resources / "theme-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["themeNames"], ["github-dark", "github-light"])
            self.assertEqual([theme["id"] for theme in manifest["themes"]], ["github-dark", "github-light"])
            notice = (resources / "licenses/tm-themes-NOTICE.txt").read_text(encoding="utf-8")
            self.assertTrue(notice.startswith("THIRD-PARTY SOFTWARE NOTICES"))
            self.assertIn("Copyright github-dark.json", notice)
            self.assertNotIn("dracula", notice)
            self.assertNotIn("nord", notice)

    def test_missing_theme_fails_without_removing_files(self):
        with TemporaryDirectory() as directory:
            resources = self.make_bundle(directory)
            result = self.trim(resources, "--keep", "github-light", "solarized-light")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("solarized-light", result.stderr)
            self.assertEqual(len(list((resources / "themes").iterdir())), 5)


if __name__ == "__main__":
    unittest.main()
