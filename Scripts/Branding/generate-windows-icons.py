#!/usr/bin/env python3
"""Create Windows package assets from the shared portable brand image."""

from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / "Platforms/Windows/src/FoldGit.App/Assets"
SOURCE = ROOT / "Shared/Resources/Branding/Images/FoldGit.png"


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGBA")
    sizes = {"StoreLogo": (50, 50), "Square44x44Logo": (44, 44), "Square150x150Logo": (150, 150), "Wide310x150Logo": (310, 150)}
    for name, (width, height) in sizes.items():
        for scale in [100, 125, 150, 200, 400]:
            output = Image.new("RGBA", (width * scale // 100, height * scale // 100))
            size = min(output.size)
            artwork = source.resize((size, size), Image.Resampling.LANCZOS)
            output.alpha_composite(artwork, ((output.width - size) // 2, (output.height - size) // 2))
            output.save(DESTINATION / f"{name}.scale-{scale}.png", optimize=True)
            if scale == 100:
                output.save(DESTINATION / f"{name}.png", optimize=True)
    source.save(DESTINATION / "FoldGit.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("Generated Windows icons from Shared/Resources/Branding/Images/FoldGit.png")


if __name__ == "__main__":
    main()
