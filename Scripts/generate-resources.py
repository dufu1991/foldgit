#!/usr/bin/env python3
"""Generate native localization resources in the requested build directory."""

import argparse
import json
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET

CATALOGS = Path(__file__).resolve().parents[1] / "Shared/Resources/Localization"


def write_resource(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != content:
        path.write_bytes(content)


def generate_macos(directory, language, catalog):
    localization = directory / f"{language}.lproj"
    strings = "\n".join(
        f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};"
        for key, value in sorted(catalog["strings"].items())
    )
    write_resource(localization / "Localizable.strings", (strings + "\n").encode("utf-8"))
    write_resource(localization / "Localizable.stringsdict", plistlib.dumps(catalog["plurals"]))


def generate_windows(directory, language, catalog):
    resource = ET.Element("root")
    for name, value in [("resmimetype", "text/microsoft-resx"), ("version", "2.0")]:
        ET.SubElement(ET.SubElement(resource, "resheader", name=name), "value").text = value
    description = ET.SubElement(resource, "data", name="AppDescription")
    ET.SubElement(description, "value").text = catalog["windows"]["Git Client"]
    ET.indent(resource)
    write_resource(
        directory / language / "Resources.resw",
        ET.tostring(resource, encoding="utf-8", xml_declaration=True) + b"\n",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("macos", "windows"))
    parser.add_argument("output_directory", type=Path)
    arguments = parser.parse_args()
    generate = generate_macos if arguments.platform == "macos" else generate_windows
    for source in sorted(CATALOGS.glob("*.json")):
        generate(arguments.output_directory, source.stem, json.loads(source.read_text(encoding="utf-8")))


if __name__ == "__main__":
    main()
