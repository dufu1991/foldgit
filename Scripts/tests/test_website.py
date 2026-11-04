"""Check the complete deployable website, including generated resource URLs."""

import hashlib
from html.parser import HTMLParser
import importlib.util
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
import changelog
PIL_AVAILABLE = importlib.util.find_spec("PIL") is not None


class PageResources(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attributes):
        for key, value in attributes:
            if value and key in ("src", "href"):
                self.urls.append(value)
            if value and key == "srcset":
                self.urls.extend(candidate.strip().split()[0] for candidate in value.split(","))


@unittest.skipUnless(PIL_AVAILABLE, "Install Scripts/build-requirements.txt")
class WebsiteBuildTests(unittest.TestCase):
    def test_build_produces_complete_pages_from_shared_sources(self):
        from PIL import Image

        spec = importlib.util.spec_from_file_location("build_website", ROOT / "Scripts/build-website.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        sources = list((ROOT / "website").rglob("*")) + list(builder.BRANDING.glob("*")) + [changelog.SOURCE]
        before = {path: hashlib.sha256(path.read_bytes()).digest() for path in sources if path.is_file()}
        with TemporaryDirectory() as directory:
            output = Path(directory) / "public"
            output.mkdir()
            (output / "stale-asset.txt").write_text("old deployment", encoding="utf-8")
            builder.build(output)
            for name in ("index.html", "manual.html", "changelog.html", "styles.css", "main.js", "i18n.js"):
                self.assertTrue((output / name).is_file(), name)
            self.assertFalse((output / "stale-asset.txt").exists())
            self.assertFalse((output / "scripts").exists())
            self.assertFalse((output / "README.md").exists())
            self.assertFalse((output / "templates").exists())
            self.assertFalse((output / "changelog.json").exists())
            expected = changelog.render_page(changelog.TEMPLATE.read_text(encoding="utf-8"), changelog.read_entries())
            self.assertEqual((output / "changelog.html").read_text(encoding="utf-8"), expected)
            for page in output.glob("*.html"):
                parser = PageResources()
                parser.feed(page.read_text(encoding="utf-8"))
                for url in parser.urls:
                    with self.subTest(page=page.name, url=url):
                        parsed = urlsplit(url)
                        if parsed.netloc and parsed.netloc != "foldgit.com":
                            continue
                        if not parsed.path or parsed.scheme in ("mailto", "data"):
                            continue
                        target = output / parsed.path.lstrip("/")
                        self.assertTrue(target.exists() or target.with_suffix(".html").exists(), url)
            css = (output / "styles.css").read_text(encoding="utf-8")
            for match in re.finditer(r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)""", css):
                url = next(value for value in match.groups() if value is not None).strip()
                if urlsplit(url).scheme:
                    continue
                self.assertTrue((output / url).is_file(), url)
            for language in ("zh", "en"):
                for scheme in ("light", "dark"):
                    name = f"main-{language}-{scheme}"
                    master = output / f"assets/screenshots/{name}@2x.webp"
                    original = builder.SOURCE / f"assets/screenshots/{name}@2x.webp"
                    self.assertEqual(master.read_bytes(), original.read_bytes())
                    with Image.open(output / f"assets/screenshots/{name}.webp") as image:
                        self.assertEqual(image.size, (1920, 988))
            for suffix in ("", "-dark"):
                for name, dimensions in ((f"favicon{suffix}.png", (180, 180)),
                                         (f"icon{suffix}.webp", (512, 512))):
                    with Image.open(output / "assets" / name) as image:
                        self.assertEqual(image.size, dimensions)
            self.assertEqual(before, {path: hashlib.sha256(path.read_bytes()).digest() for path in before})


if __name__ == "__main__":
    unittest.main()
