"""Guard release copy selection, bilingual validation and generated-page freshness."""
from contextlib import redirect_stdout
from copy import deepcopy
from io import StringIO
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import changelog


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.entries = [
            {"version": "0.1.1", "date": "2026-10-28", "zh": ["新增菜单。"], "en": ["Add menus."]},
            {"version": "0.1.0", "date": "2026-10-27", "zh": ["首次发布。"], "en": ["First release."]},
        ]

    def test_version_bump_requires_new_notes(self):
        with self.assertRaisesRegex(SystemExit, "Add bilingual notes for version 0.2.0"):
            changelog.validate(self.entries, "0.2.0")

    def test_both_languages_are_required(self):
        for language in ("zh", "en"):
            with self.subTest(language=language):
                entries = deepcopy(self.entries)
                entries[0][language] = []
                with self.assertRaisesRegex(SystemExit, f"needs {language} release notes"):
                    changelog.validate(entries, "0.1.1")

    def test_translations_have_corresponding_items(self):
        self.entries[0]["en"].append("Another change.")
        with self.assertRaisesRegex(SystemExit, "matching Chinese and English items"):
            changelog.validate(self.entries, "0.1.1")

    def test_duplicate_or_out_of_order_versions_fail(self):
        for number in ("0.1.1", "0.2.0"):
            with self.subTest(version=number):
                self.entries[1]["version"] = number
                with self.assertRaisesRegex(SystemExit, "unique and ordered newest first"):
                    changelog.validate(self.entries, "0.1.1")

    def test_placeholder_and_multiline_notes_fail(self):
        for value in ("", "  ", "Add menus.\nAnother change."):
            with self.subTest(value=value):
                self.entries[0]["en"] = [value]
                with self.assertRaisesRegex(SystemExit, "non-empty, single-line"):
                    changelog.validate(self.entries, "0.1.1")

    def test_release_selects_requested_version_in_both_languages(self):
        notes = changelog.release_notes(self.entries, "0.1.0")
        self.assertIn("- 首次发布。", notes)
        self.assertIn("- First release.", notes)
        self.assertNotIn("Add menus.", notes)
        self.assertNotIn("新增菜单。", notes)
        self.assertFalse(any(line.startswith("#") for line in notes.splitlines()))
        self.assertNotIn("\n- \n", notes)
        self.assertIn("- 首次发布。\n\n---\n\n- First release.", notes)

    def test_missing_release_does_not_use_latest_notes(self):
        with self.assertRaisesRegex(SystemExit, "No release notes found for 9.0.0"):
            changelog.release_notes(self.entries, "9.0.0")

    def test_website_treats_release_copy_as_text(self):
        self.entries[0]["en"] = ['Show <script>alert("hello")</script> & branches.']
        html = changelog.render_entries(self.entries)
        self.assertIn("&lt;script&gt;", html)
        self.assertNotIn("<script>", html)
        self.assertIn('class="show-zh" lang="zh-CN"', html)
        self.assertIn('class="show-en" lang="en"', html)

    def test_regeneration_preserves_page_shell_and_is_repeatable(self):
        page = "header\n" + changelog.START + "\nold\n" + changelog.END + "\nfooter"
        generated = changelog.render_page(page, self.entries)
        self.assertTrue(generated.startswith("header\n"))
        self.assertTrue(generated.endswith("\nfooter"))
        self.assertEqual(changelog.render_page(generated, self.entries), generated)

    def test_ci_rejects_stale_page_until_it_is_regenerated(self):
        with TemporaryDirectory() as directory:
            source = Path(directory) / "changelog.json"
            page = Path(directory) / "changelog.html"
            source.write_text(json.dumps(self.entries), encoding="utf-8")
            page.write_text(changelog.START + "\n" + changelog.END, encoding="utf-8")
            with patch.object(changelog, "SOURCE", source), patch.object(changelog, "PAGE", page), \
                    patch.object(changelog, "current_version", return_value="0.1.1"), redirect_stdout(StringIO()):
                with patch.object(sys, "argv", ["changelog.py", "--check"]):
                    with self.assertRaisesRegex(SystemExit, "Changelog HTML is stale"):
                        changelog.main()
                with patch.object(sys, "argv", ["changelog.py", "--write"]):
                    changelog.main()
                with patch.object(sys, "argv", ["changelog.py", "--check"]):
                    changelog.main()


if __name__ == "__main__":
    unittest.main()
