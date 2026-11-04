#!/usr/bin/env python3
"""Prepare authenticated Sparkle release assets from an already packaged app."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from changelog import read_entries, release_entry

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
XML_LANGUAGE = "{http://www.w3.org/XML/1998/namespace}lang"
ET.register_namespace("sparkle", NAMESPACE["sparkle"])


def localize_notes(item, entry):
    for description in item.findall("description"):
        item.remove(description)
    # Match the app's supported languages, including English fallbacks for each
    # non-Chinese language, so a secondary system language cannot select Chinese.
    languages = sorted(path.stem for path in (ROOT / "Shared/Resources/Localization").glob("*.json"))
    for language in languages:
        description = ET.SubElement(item, "description", {
            XML_LANGUAGE: language,
            f"{{{NAMESPACE['sparkle']}}}format": "plain-text",
        })
        description.text = "\n".join(f"• {text}" for text in entry["zh" if language.startswith("zh") else "en"])


def prepare(app, archive, output, tools, key, download_url):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not info["SURequireSignedFeed"] or not info["SUVerifyUpdateBeforeExtraction"]:
        raise ValueError("The app must require signed feeds and pre-extraction update verification")
    if not info["SUPublicEDKey"] or not info["SUFeedURL"]:
        raise ValueError("The app must include its update feed and public signing key")
    entry = release_entry(read_entries(), version)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="FoldGit-updates-") as directory:
        work = Path(directory)
        name = "FoldGit-macOS-arm64.dmg"
        shutil.copy2(archive, work / name)
        feed = work / "appcast.xml"
        subprocess.run([str(tools / "generate_appcast"), "--ed-key-file", "-",
                        "--download-url-prefix", download_url,
                        "--maximum-deltas", "0", "--maximum-versions", "1", "-o", str(feed), str(work)],
                       input=key, text=True, check=True)
        document = ET.parse(feed)
        items = document.findall("./channel/item")
        if len(items) != 1:
            raise ValueError("Expected exactly one signed update in the appcast")
        item = items[0]
        enclosure = item.find("enclosure")
        if enclosure is None or f"{{{NAMESPACE['sparkle']}}}edSignature" not in enclosure.attrib:
            raise ValueError("The update was not signed with the app's EdDSA key")
        signature = enclosure.attrib[f"{{{NAMESPACE['sparkle']}}}edSignature"]
        if (item.findtext("sparkle:version", namespaces=NAMESPACE) != str(build)
                or item.findtext("sparkle:shortVersionString", namespaces=NAMESPACE) != version
                or int(enclosure.attrib["length"]) != archive.stat().st_size):
            raise ValueError("The appcast does not match the packaged app")
        # Sparkle omits the update signature when the app's public key does not match.
        subprocess.run([str(tools / "sign_update"), "--ed-key-file", "-", "--verify",
                        str(work / name), signature], input=key, text=True, check=True)
        localize_notes(item, entry)
        document.write(feed, encoding="utf-8", xml_declaration=True)
        # Localized descriptions must be finalized before the feed is signed.
        subprocess.run([str(tools / "sign_update"), "--ed-key-file", "-", str(feed)],
                       input=key, text=True, check=True)
        subprocess.run([str(tools / "sign_update"), "--ed-key-file", "-", "--verify", str(feed)],
                       input=key, text=True, check=True)
        shutil.copy2(work / name, output / name)
        shutil.copy2(feed, output / "appcast.xml")
    print(f"Prepared signed Sparkle update {version} ({build}) in {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tools", required=True, type=Path)
    parser.add_argument("--private-key-file", type=Path)
    parser.add_argument("--download-url-prefix")
    args = parser.parse_args()
    key = (args.private_key_file.read_text().strip() if args.private_key_file
           else os.environ.get("SPARKLE_EDDSA_PRIVATE_KEY", "").strip())
    if not key:
        parser.error("SPARKLE_EDDSA_PRIVATE_KEY must be configured before publishing an update")
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    url = args.download_url_prefix or ("https://github.com/dufu1991/foldgit/releases/download/v"
                                       + info["CFBundleShortVersionString"] + "/")
    prepare(args.app, args.archive, args.output, args.tools, key, url)
