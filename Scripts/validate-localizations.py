#!/usr/bin/env python3
"""Validate translations and optionally compare compiler-extracted localization keys."""

import argparse
from collections import Counter
import json
import plistlib
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Platforms/macOS/Resources"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|u|@)")
PLURALS = {
    "en": {"one", "other"},
    "zh-Hans": {"other"},
    "zh-Hant": {"other"},
    "ja": {"other"},
    "ko": {"other"},
    "ru": {"one", "few", "many", "other"},
    "fr": {"one", "other"},
    "es": {"one", "other"},
}


def read_strings(path):
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def validate(extracted_directory):
    errors = []
    source_strings = read_strings(RESOURCES / "en.lproj/Localizable.strings")
    source_plurals = plistlib.loads((RESOURCES / "en.lproj/Localizable.stringsdict").read_bytes())
    strings = set(source_strings) | set(source_plurals)
    directories = {path.stem for path in RESOURCES.glob("*.lproj")}
    if directories != set(PLURALS):
        errors.append("Missing or unexpected language directories")
    for language, categories in PLURALS.items():
        directory = RESOURCES / f"{language}.lproj"
        ordinary = read_strings(directory / "Localizable.strings")
        plurals = plistlib.loads((directory / "Localizable.stringsdict").read_bytes())
        if set(ordinary) != set(source_strings) or set(plurals) != set(source_plurals):
            errors.append(f"{language}: translation keys differ from English")
        if set(ordinary) & set(plurals):
            errors.append(f"{language}: keys appear in both strings and plural resources")
        units = list(ordinary.items())
        for key, entry in plurals.items():
            if entry.get("NSStringLocalizedFormatKey") != "%#@count@":
                errors.append(f"{language} / {key}: invalid plural format")
            rule = entry["count"]
            if rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType":
                errors.append(f"{language} / {key}: invalid plural rule type")
            if rule.get("NSStringFormatValueTypeKey") != "lld":
                errors.append(f"{language} / {key}: invalid plural argument type")
            variants = {category: value for category, value in rule.items() if not category.startswith("NSString")}
            if not categories.issubset(variants):
                errors.append(f"{language} / {key}: missing plural categories")
            units.extend((key, value) for value in variants.values())
        for key, value in units:
            if not value.strip() or "\ufffd" in value:
                errors.append(f"{language} / {key}: incomplete or invalid translation")
            if Counter(PLACEHOLDER.findall(key)) != Counter(PLACEHOLDER.findall(value)):
                errors.append(f"{language} / {key}: interpolation placeholders differ")
            if language.startswith("zh") and re.search(
                r"[\u3400-\u9fff][A-Za-z0-9]|[A-Za-z0-9][\u3400-\u9fff]", value
            ):
                errors.append(f"{language} / {key}: missing space around Latin text or numbers")
    if extracted_directory:
        extracted_files = list(extracted_directory.rglob("*.stringsdata"))
        if not extracted_files:
            errors.append("No compiler-extracted .stringsdata files found")
        for path in extracted_files:
            data = json.loads(path.read_text(encoding="utf-8"))
            for item in data.get("tables", {}).get("Localizable", []):
                key = item["key"]
                if any(character.isalpha() for character in key) and key not in strings:
                    errors.append(f"{path.stem}: untranslated source key {key!r}")
    for error in sorted(set(errors)):
        print(error)
    if errors:
        raise SystemExit(1)
    print(f"Validated {len(strings)} keys across {len(PLURALS)} languages")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extracted-directory", type=Path)
    arguments = parser.parse_args()
    validate(arguments.extracted_directory)
