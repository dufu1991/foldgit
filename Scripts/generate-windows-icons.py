#!/usr/bin/env python3
"""Generate Windows application and installer icons from the shared brand image."""

import argparse
from io import BytesIO
from pathlib import Path

from PIL import Image

SOURCE = Path(__file__).resolve().parents[1] / "Shared/Resources/Branding/Images/FoldGit.webp"
SIZES = {"StoreLogo": (50, 50), "Square44x44Logo": (44, 44),
         "Square150x150Logo": (150, 150), "Wide310x150Logo": (310, 150)}


def resources():
    with Image.open(SOURCE) as image:
        source = image.convert("RGBA")
    for name, (width, height) in SIZES.items():
        for scale in (100, 125, 150, 200, 400):
            output = Image.new("RGBA", (width * scale // 100, height * scale // 100))
            size = min(output.size)
            artwork = source.resize((size, size), Image.Resampling.LANCZOS)
            output.alpha_composite(artwork, ((output.width - size) // 2, (output.height - size) // 2))
            data = BytesIO()
            output.save(data, format="PNG", optimize=True)
            yield f"{name}.scale-{scale}.png", data.getvalue()
            if scale == 100:
                yield f"{name}.png", data.getvalue()
    data = BytesIO()
    source.save(data, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                                         (64, 64), (128, 128), (256, 256)])
    yield "FoldGit.ico", data.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--check", action="store_true", help="Verify existing build or package assets")
    arguments = parser.parse_args()
    if not arguments.check:
        arguments.output_directory.mkdir(parents=True, exist_ok=True)
    stale = []
    for name, content in resources():
        path = arguments.output_directory / name
        if path.is_file() and path.read_bytes() == content:
            continue
        if arguments.check:
            stale.append(name)
        else:
            path.write_bytes(content)
    if stale:
        raise SystemExit("Missing or incorrect Windows icons in " + str(arguments.output_directory)
                         + ":\n" + "\n".join(stale))


if __name__ == "__main__":
    main()
