#!/usr/bin/env python3
"""Read, check or set the FoldGit version across macOS and Windows.

The macOS MARKETING_VERSION is the source of truth. The Windows package identity
and About text must match it when the Windows client is present.

    python3 Scripts/version.py            # print the version, fail on mismatch
    python3 Scripts/version.py set 0.2.0  # update every platform and bump the macOS build number
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
XCCONFIG = ROOT / "Platforms/macOS/Configuration/Base.xcconfig"
MANIFEST = ROOT / "Platforms/Windows/src/FoldGit.App/Package.appxmanifest"
ABOUT = ROOT / "Platforms/Windows/src/FoldGit.App/MainWindow.Dialogs.cs"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")

MARKETING = re.compile(r"^(MARKETING_VERSION = )(\S+)$", re.MULTILINE)
BUILD = re.compile(r"^(CURRENT_PROJECT_VERSION = )(\d+)$", re.MULTILINE)
IDENTITY = re.compile(r'(<Identity\b[^>]*\bVersion=")([^"]+)(")')
ABOUT_TEXT = re.compile(r'("FoldGit )(\d+\.\d+\.\d+)(")')


def read(pattern, path, group=2):
    match = pattern.search(path.read_text(encoding="utf-8"))
    if not match:
        sys.exit(f"Could not find the version in {path.relative_to(ROOT)}")
    return match.group(group)


def check():
    version = read(MARKETING, XCCONFIG)
    if not SEMVER.match(version):
        sys.exit(f"MARKETING_VERSION must look like 1.2.3, found {version}")
    errors = []
    if MANIFEST.exists() and read(IDENTITY, MANIFEST) != f"{version}.0":
        errors.append(f"{MANIFEST.relative_to(ROOT)} has {read(IDENTITY, MANIFEST)}, expected {version}.0")
    if ABOUT.exists() and read(ABOUT_TEXT, ABOUT) != version:
        errors.append(f"{ABOUT.relative_to(ROOT)} shows {read(ABOUT_TEXT, ABOUT)}, expected {version}")
    if errors:
        sys.exit("Version mismatch:\n  " + "\n  ".join(errors) + "\nRun: python3 Scripts/version.py set " + version)
    return version


def replace(pattern, path, value):
    text = path.read_text(encoding="utf-8")
    path.write_text(pattern.sub(lambda m: m.group(1) + value + m.group(3) if m.lastindex == 3 else m.group(1) + value, text, count=1), encoding="utf-8")


def set_version(version):
    if not SEMVER.match(version):
        sys.exit(f"Use a version like 1.2.3, not {version}")
    replace(MARKETING, XCCONFIG, version)
    replace(BUILD, XCCONFIG, str(int(read(BUILD, XCCONFIG)) + 1))
    if MANIFEST.exists():
        replace(IDENTITY, MANIFEST, f"{version}.0")
    if ABOUT.exists():
        replace(ABOUT_TEXT, ABOUT, version)
    print(check())


if __name__ == "__main__":
    if len(sys.argv) == 1:
        print(check())
    elif len(sys.argv) == 3 and sys.argv[1] == "set":
        set_version(sys.argv[2])
    else:
        sys.exit(__doc__)
