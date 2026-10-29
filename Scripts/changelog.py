#!/usr/bin/env python3
"""Validate bilingual release copy, generate the static page, or print release notes.

    python3 Scripts/changelog.py --write
    python3 Scripts/changelog.py --check
    python3 Scripts/changelog.py --release 0.1.1
"""
import argparse
from datetime import date
from html import escape
import json
from pathlib import Path
import re
import sys

from version import check as current_version

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "website/changelog.json"
PAGE = ROOT / "website/changelog.html"
START = "    <!-- changelog:start -->"
END = "    <!-- changelog:end -->"
VERSION = re.compile(r"\d+\.\d+\.\d+")


def validate(entries, version):
    if not isinstance(entries, list) or not entries:
        sys.exit("Changelog must contain at least one release.")
    previous = None
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"version", "date", "zh", "en"}:
            sys.exit("Each release must contain version, date, zh and en.")
        number = entry["version"]
        if not isinstance(number, str) or not VERSION.fullmatch(number):
            sys.exit(f"Invalid changelog version: {number}")
        parts = tuple(map(int, number.split(".")))
        if previous is not None and parts >= previous:
            sys.exit("Changelog versions must be unique and ordered newest first.")
        previous = parts
        day = entry["date"]
        if not isinstance(day, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            sys.exit(f"Invalid release date for {number}: {day}")
        date.fromisoformat(day)
        for language in ("zh", "en"):
            items = entry[language]
            if not isinstance(items, list) or not items:
                sys.exit(f"Release {number} needs {language} release notes.")
            if any(not isinstance(item, str) or not item.strip() or item != item.strip()
                   or "\n" in item or "\r" in item for item in items):
                sys.exit(f"Release {number} needs non-empty, single-line {language} notes.")
        if len(entry["zh"]) != len(entry["en"]):
            sys.exit(f"Release {number} must have matching Chinese and English items.")
    if entries[0]["version"] != version:
        sys.exit(f"Add bilingual notes for version {version} to website/changelog.json, then run "
                 "python3 Scripts/changelog.py --write.")


def render_entries(entries):
    articles = []
    for index, entry in enumerate(entries):
        number = entry["version"]
        latest = ('<span class="release-latest"><span class="show-zh">最新版本</span>'
                  '<span class="show-en">Latest</span></span>') if index == 0 else ""
        lines = [
            f'    <article class="release glass" id="v{number}" aria-labelledby="title-{number}">',
            '      <header class="release-head">',
            f'        <h2 id="title-{number}"><a href="#v{number}">{number}</a></h2>',
            f'        {latest}' if latest else None,
            f'        <time datetime="{entry["date"]}">{entry["date"]}</time>',
            '      </header>',
        ]
        for language in ("zh", "en"):
            html_language = "zh-CN" if language == "zh" else "en"
            lines.append(f'      <ul class="show-{language}" lang="{html_language}">')
            lines.extend(f'        <li>{escape(item)}</li>' for item in entry[language])
            lines.append('      </ul>')
        lines.extend([
            f'      <a class="release-link" href="https://github.com/dufu1991/foldgit/releases/tag/v{number}">',
            '        <span class="show-zh">下载此版本</span><span class="show-en">Download this release</span><span aria-hidden="true"> ↗</span>',
            '      </a>',
            '    </article>',
        ])
        articles.append("\n".join(line for line in lines if line is not None))
    return "\n\n".join(articles)


def render_page(page, entries):
    if page.count(START) != 1 or page.count(END) != 1 or page.index(START) >= page.index(END):
        sys.exit("The changelog page must contain one ordered pair of changelog markers.")
    before = page.split(START)[0]
    after = page.split(END)[1]
    return before + START + "\n" + render_entries(entries) + "\n" + END + after


def release_notes(entries, version):
    entry = next((entry for entry in entries if entry["version"] == version), None)
    if entry is None:
        sys.exit(f"No release notes found for {version}.")
    return ("\n".join(f"- {item}" for item in entry["zh"])
            + "\n\n---\n\n" + "\n".join(f"- {item}" for item in entry["en"]) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="Regenerate the static changelog page")
    mode.add_argument("--check", action="store_true", help="Check current-version notes and generated HTML")
    mode.add_argument("--release", metavar="VERSION", help="Print both languages for exactly this version")
    args = parser.parse_args()
    entries = json.loads(SOURCE.read_text(encoding="utf-8"))
    validate(entries, current_version())
    page = PAGE.read_text(encoding="utf-8")
    generated = render_page(page, entries)
    if args.write:
        PAGE.write_text(generated, encoding="utf-8")
        print("Updated website/changelog.html.")
    elif generated != page:
        sys.exit("Changelog HTML is stale. Run: python3 Scripts/changelog.py --write")
    elif args.release:
        print(release_notes(entries, args.release), end="")
    else:
        print("Changelog versions, translations and HTML are up to date.")


if __name__ == "__main__":
    main()
