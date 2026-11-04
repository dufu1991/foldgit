"""Verify real Sparkle signatures and fail closed for changed or mismatched updates."""

import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
CONFIGURED = all(os.environ.get(name) for name in (
    "FOLDGIT_SPARKLE_TEST_APP", "FOLDGIT_SPARKLE_TEST_ARCHIVE", "SPARKLE_TOOLS_DIRECTORY",
    "SPARKLE_EDDSA_PRIVATE_KEY",
))


class SparkleLocalizationTests(unittest.TestCase):
    def test_notes_use_existing_chinese_and_english_for_all_app_languages(self):
        spec = importlib.util.spec_from_file_location("sparkle_release", ROOT / "Scripts/sparkle.py")
        release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release)
        item = ET.fromstring('<item><description>old bilingual notes</description><enclosure length="42" /></item>')
        entry = {"zh": ["支持复制仓库路径。"], "en": ["Copy repository paths.", "Keep <names> & symbols."]}
        release.localize_notes(item, entry)
        item = ET.fromstring(ET.tostring(item, encoding="utf-8"))
        descriptions = item.findall("description")
        languages = {path.stem for path in (ROOT / "Shared/Resources/Localization").glob("*.json")}
        self.assertEqual({node.attrib[release.XML_LANGUAGE] for node in descriptions}, languages)
        self.assertEqual(len(descriptions), len(languages))
        self.assertEqual(descriptions[0].attrib[release.XML_LANGUAGE], "en")
        for node in descriptions:
            language = node.attrib[release.XML_LANGUAGE]
            expected = entry["zh" if language.startswith("zh") else "en"]
            self.assertEqual(node.text, "\n".join(f"• {text}" for text in expected))
            self.assertEqual(node.attrib[f"{{{release.NAMESPACE['sparkle']}}}format"], "plain-text")
        self.assertEqual(item.find("enclosure").attrib, {"length": "42"})


@unittest.skipUnless(CONFIGURED, "Requires a packaged app and Sparkle signing tools")
class SparkleReleaseTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("sparkle_release", ROOT / "Scripts/sparkle.py")
        self.release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.release)
        self.app = Path(os.environ["FOLDGIT_SPARKLE_TEST_APP"]).resolve()
        self.archive = Path(os.environ["FOLDGIT_SPARKLE_TEST_ARCHIVE"]).resolve()
        self.tools = Path(os.environ["SPARKLE_TOOLS_DIRECTORY"]).resolve()
        self.key = os.environ["SPARKLE_EDDSA_PRIVATE_KEY"]

    def prepare(self, output, key=None):
        self.release.prepare(self.app, self.archive, output, self.tools,
                             self.key if key is None else key, "https://example.com/updates/")

    def verify(self, path, signature=None):
        arguments = [str(self.tools / "sign_update"), "--ed-key-file", "-", "--verify", str(path)]
        if signature is not None:
            arguments.append(signature)
        return subprocess.run(arguments, input=self.key, text=True, capture_output=True).returncode

    def test_release_matches_bundle_and_keeps_localized_notes(self):
        with TemporaryDirectory() as directory:
            output = Path(directory)
            self.prepare(output)
            feed = output / "appcast.xml"
            info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
            item = ET.parse(feed).find("./channel/item")
            self.assertEqual(item.findtext("sparkle:version", namespaces=self.release.NAMESPACE),
                             info["CFBundleVersion"])
            entry = self.release.release_entry(self.release.read_entries(), info["CFBundleShortVersionString"])
            descriptions = item.findall("description")
            self.assertEqual(len(descriptions), len(list((ROOT / "Shared/Resources/Localization").glob("*.json"))))
            for node in descriptions:
                language = node.attrib[self.release.XML_LANGUAGE]
                expected = entry["zh" if language.startswith("zh") else "en"]
                self.assertEqual(node.text, "\n".join(f"• {text}" for text in expected))
            self.assertEqual((output / "FoldGit-macOS-arm64.dmg").read_bytes(), self.archive.read_bytes())
            self.assertEqual(self.verify(feed), 0)

    def test_changed_archives_and_feeds_are_rejected(self):
        with TemporaryDirectory() as directory:
            output = Path(directory)
            self.prepare(output)
            feed = output / "appcast.xml"
            signature = ET.parse(feed).find("./channel/item/enclosure").attrib[
                f"{{{self.release.NAMESPACE['sparkle']}}}edSignature"]
            archive = output / "FoldGit-macOS-arm64.dmg"
            archive.write_bytes(archive.read_bytes() + b"tampered")
            self.assertNotEqual(self.verify(archive, signature), 0)
            original = feed.read_text()
            for node in ET.parse(feed).findall("./channel/item/description"):
                language = node.attrib[self.release.XML_LANGUAGE]
                with self.subTest(language=language):
                    pattern = rf'(<description\b[^>]*xml:lang="{re.escape(language)}"[^>]*>)(.*?)(</description>)'
                    changed, count = re.subn(pattern, lambda match: match[1] + match[2] + " tampered" + match[3],
                                             original, count=1, flags=re.DOTALL)
                    self.assertEqual(count, 1)
                    feed.write_text(changed)
                    self.assertNotEqual(self.verify(feed), 0)

    def test_sparkle_selects_notes_for_app_languages_and_secondary_preferences(self):
        with TemporaryDirectory() as directory:
            output = Path(directory)
            self.prepare(output)
            languages = sorted(path.stem for path in (ROOT / "Shared/Resources/Localization").glob("*.json"))
            # Foundation's language matching also considers the host bundle's
            # localizations. Give this headless parser probe the app's languages.
            contents = output / "LanguageProbe.app/Contents"
            probe = contents / "MacOS/language-probe"
            probe.parent.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.dufu.foldgit.language-probe",
                "CFBundleExecutable": "language-probe", "CFBundlePackageType": "APPL",
                "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": languages,
            }))
            subprocess.run(["xcrun", "clang", str(ROOT / "Scripts/tests/fixtures/SparkleLanguageProbe.m"),
                            "-fobjc-arc", "-F", str(self.tools.parent), "-framework", "Sparkle",
                            "-framework", "Foundation", f"-Wl,-rpath,{self.tools.parent}", "-o", str(probe)],
                           check=True, capture_output=True)
            info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
            entry = self.release.release_entry(self.release.read_entries(), info["CFBundleShortVersionString"])
            preferences = [([path.stem], "zh" if path.stem.startswith("zh") else "en")
                           for path in sorted((ROOT / "Shared/Resources/Localization").glob("*.json"))]
            preferences += [(["fr", "zh-Hans"], "en"), (["ja", "zh-Hant"], "en"),
                            (["zh-CN"], "zh"), (["zh-TW"], "zh"), (["zh-HK"], "zh"), (["pt-BR"], "en")]
            for languages, expected_language in preferences:
                with self.subTest(preferences=languages):
                    result = subprocess.run([str(probe), str(output / "appcast.xml"), "-AppleLanguages",
                                             "(" + ", ".join(languages) + ")"], check=True,
                                            capture_output=True, text=True)
                    expected = "\n".join(f"• {text}" for text in entry[expected_language])
                    self.assertEqual(result.stdout.strip(), expected)

    def test_wrong_private_key_cannot_publish_an_update(self):
        with TemporaryDirectory() as directory:
            output = Path(directory)
            wrong_key = base64.b64encode(bytes(32)).decode()
            with self.assertRaises((ValueError, KeyError, subprocess.CalledProcessError)):
                self.prepare(output, key=wrong_key)
            self.assertEqual(list(output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
