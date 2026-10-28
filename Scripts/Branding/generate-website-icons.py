#!/usr/bin/env python3
"""Create landing page icons from the shared portable brand images."""

from pathlib import Path
import subprocess
import tempfile
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Shared/Resources/Branding/Images"
DESTINATION = ROOT / "website/assets"


def main():
    with tempfile.TemporaryDirectory() as temporary:
        for suffix in ["", "-dark"]:
            source = Image.open(SOURCE / f"FoldGit{suffix}.png").convert("RGBA")
            source.resize((180, 180), Image.Resampling.LANCZOS).save(DESTINATION / f"favicon{suffix}.png", optimize=True)
            icon = Path(temporary) / f"icon{suffix}.png"
            source.resize((512, 512), Image.Resampling.LANCZOS).save(icon)
            subprocess.run(["cwebp", "-quiet", "-q", "90", "-alpha_q", "100", str(icon),
                            "-o", str(DESTINATION / f"icon{suffix}.webp")], check=True)
    print("Generated website icons from Shared/Resources/Branding/Images")


if __name__ == "__main__":
    main()
