#!/usr/bin/env python3
"""Validate portable Windows inputs without requiring the Windows XAML compiler."""

import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = ROOT / "Platforms/Windows"
errors = []

catalogs = {path.stem: json.loads(path.read_text(encoding="utf-8")) for path in (ROOT / "Shared/Resources/Localization").glob("*.json")}
source = catalogs["en"]
for language, catalog in catalogs.items():
    for section in ["strings", "plurals", "windows"]:
        if set(catalog[section]) != set(source[section]):
            errors.append(f"{language}: {section} keys differ")
    for key, value in catalog["windows"].items():
        if not value.strip() or "\ufffd" in value:
            errors.append(f"{language}: invalid Windows translation {key}")
        if language.startswith("zh") and re.search(r"[\u3400-\u9fff][A-Za-z0-9]|[A-Za-z0-9][\u3400-\u9fff]", value):
            errors.append(f"{language}: missing space around Latin text or numbers: {key}")

manifest = json.loads((ROOT / "Shared/Resources/FileIcons/MaterialFileIcons.json").read_text())
icons = set(manifest["fileNames"].values()) | set(manifest["fileExtensions"].values()) | {manifest["defaultIcon"]}
icons |= {name + ".light" for name in manifest["lightIcons"]}
for name in icons:
    if not (ROOT / f"Shared/Resources/FileIcons/MaterialFileIcons/{name}.svg").is_file():
        errors.append(f"Missing shared file icon: {name}")

sources = "\n".join(path.read_text(encoding="utf-8") for path in (WINDOWS / "src/FoldGit.App").rglob("*.cs") if not {"obj", "bin"} & set(path.parts))
keys = set(source["strings"]) | set(source["windows"])
for key in re.findall(r'(?:\bL|\bText\.Get|\bText\.Count|\bModel\.Text\.Get|\bToggle)\([^\n]*?"([^"\n]+)"', sources):
    if key not in keys and key not in source["plurals"]:
        errors.append(f"Missing Windows localization: {key}")
for path in WINDOWS.rglob("*"):
    if {"obj", "bin", "AppPackages"} & set(path.parts) or not path.is_file():
        continue
    if path.suffix in {".xaml", ".csproj", ".props", ".manifest", ".appxmanifest", ".resw", ".slnx"}:
        ET.parse(path)
    if path.suffix == ".cs" and "\ufffd" in path.read_text(encoding="utf-8"):
        errors.append(f"Invalid Unicode: {path.relative_to(ROOT)}")
for path in (WINDOWS / "src/FoldGit.Core").rglob("*.cs"):
    if {"obj", "bin"} & set(path.parts):
        continue
    if re.search(r"using (Microsoft\.UI|Windows\.UI|FoldGit\.Platform)", path.read_text()):
        errors.append(f"Native dependency in core: {path.relative_to(ROOT)}")
for path in (ROOT / "Platforms/macOS/Sources").rglob("*.swift"):
    if re.search(r"FoundationModels|IntelligenceClient|systemLanguageModelAvailability", path.read_text()):
        errors.append(f"Remaining macOS AI integration: {path.relative_to(ROOT)}")
if errors:
    raise SystemExit("\n".join(sorted(set(errors))))
print(f"Validated Windows inputs, {len(catalogs)} catalogs and {len(icons)} shared file icons")
