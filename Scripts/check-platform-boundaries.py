#!/usr/bin/env python3
"""Keep the portable module independent of native application frameworks."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Shared/Sources/FoldGitCore"
FORBIDDEN = {"AppKit", "SwiftUI", "FoundationModels", "CryptoKit", "OSLog", "Darwin", "WinSDK"}
errors = []
for path in CORE.rglob("*.swift"):
    source = path.read_text(encoding="utf-8")
    imports = set(re.findall(r"^(?:public |internal )?import\s+(\w+)", source, re.MULTILINE))
    for name in imports & FORBIDDEN:
        errors.append(f"{path.relative_to(ROOT)}: native dependency {name}")
    for name in ["AutoFetchScheduler", "PreferenceKey", "AppPreferences", "NSApplication", "NSWorkspace"]:
        if re.search(rf"\b{name}\b", source):
            errors.append(f"{path.relative_to(ROOT)}: application dependency {name}")
    if "\ufffd" in source:
        errors.append(f"{path.relative_to(ROOT)}: invalid Unicode text")
if not CORE.is_dir() or not list(CORE.rglob("*.swift")):
    errors.append("The shared module is missing")
for name in ["Sources", "Resources", "Tests", "Configuration", "FoldGit.xcodeproj", "project.yml"]:
    if (ROOT / name).exists():
        errors.append(f"Unexpected platform-owned root entry: {name}")
for error in errors:
    print(error)
if errors:
    raise SystemExit(1)
print(f"Validated platform boundaries for {len(list(CORE.rglob('*.swift')))} shared Swift files")

windows_core = ROOT / "Platforms/Windows/src/FoldGit.Core"
for path in windows_core.rglob("*.cs"):
    if {"obj", "bin"} & set(path.parts):
        continue
    if re.search(r"using (Microsoft\.UI|Windows\.UI|FoldGit\.Platform)", path.read_text(encoding="utf-8")):
        raise SystemExit(f"{path.relative_to(ROOT)}: native dependency in C# core")
