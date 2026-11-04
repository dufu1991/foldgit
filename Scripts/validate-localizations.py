#!/usr/bin/env python3
"""Validate translations and optionally compare compiler-extracted localization keys."""

import argparse
from collections import Counter
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CATALOGS = ROOT / "Shared/Resources/Localization"
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


def validate(extracted_directory):
    errors = []
    catalogs = {path.stem: json.loads(path.read_text(encoding="utf-8")) for path in CATALOGS.glob("*.json")}
    if set(catalogs) != set(PLURALS):
        raise SystemExit("Missing or unexpected language catalogs")
    source = catalogs["en"]
    strings = set(source["strings"]) | set(source["plurals"])
    for language, categories in PLURALS.items():
        catalog = catalogs[language]
        ordinary = catalog["strings"]
        plurals = catalog["plurals"]
        if any(set(catalog[section]) != set(source[section]) for section in ("strings", "plurals", "windows")):
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
