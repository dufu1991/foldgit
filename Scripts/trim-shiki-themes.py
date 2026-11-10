#!/usr/bin/env python3
"""Keep only the Shiki themes FoldGit uses in the app's copy of the Shiki resource bundle.

Themes load on demand, so removed files are never read. The manifest and the theme notices
are trimmed to match, so the bundle never lists a theme or a notice for a file it lacks.
"""

import argparse
import json
from pathlib import Path

# Keep in sync with FileSyntaxHighlighter, which requests only these two themes.
DEFAULT_THEMES = ("github-light", "github-dark")
NOTICE = Path("licenses/tm-themes-NOTICE.txt")
SEPARATOR = "=" * 105


def write_if_changed(path, text):
    if path.read_text(encoding="utf-8") != text:
        path.write_text(text, encoding="utf-8")


def trim_manifest(resources, keep):
    path = resources / "theme-manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    themes = [theme for theme in manifest["themes"] if theme["id"] in keep]
    missing = keep - {theme["id"] for theme in themes}
    if missing:
        raise SystemExit(f"Shiki bundle has no theme named {', '.join(sorted(missing))}")
    manifest["themes"] = themes
    manifest["themeNames"] = [name for name in manifest["themeNames"] if name in keep]
    write_if_changed(path, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return {theme["resource"] for theme in themes}


def trim_theme_files(resources, resources_to_keep):
    for path in (resources / "themes").glob("*.json"):
        if f"themes/{path.name}" not in resources_to_keep:
            path.unlink()


def trim_notice(resources, keep):
    path = resources / NOTICE
    if not path.exists():
        return
    header, *sections = path.read_text(encoding="utf-8").split(SEPARATOR)
    files = {f"{name}.json" for name in keep}
    kept = []
    for section in sections:
        listed = next((line for line in section.splitlines() if line.startswith("Files:")), None)
        if listed is None or files & {name.strip() for name in listed[len("Files:"):].split(",")}:
            kept.append(section)
    write_if_changed(path, SEPARATOR.join([header, *kept]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="ShikiSwift_Shiki.bundle inside the built app")
    parser.add_argument("--keep", nargs="+", default=DEFAULT_THEMES, help="theme IDs to keep")
    args = parser.parse_args()
    resources = args.bundle / "Contents/Resources"
    if not resources.is_dir():
        resources = args.bundle
    keep = set(args.keep)
    trim_theme_files(resources, trim_manifest(resources, keep))
    trim_notice(resources, keep)


if __name__ == "__main__":
    main()
