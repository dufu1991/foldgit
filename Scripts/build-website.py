#!/usr/bin/env python3
"""Build the static website and derive display assets from shared originals."""

from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "website"
BRANDING = ROOT / "Shared/Resources/Branding/Images"
OUTPUT = ROOT / "dist/website"


def build(output):
    subprocess.run([sys.executable, str(ROOT / "Scripts/changelog.py"), "--check"], check=True)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for path in SOURCE.iterdir():
        if path.suffix in (".html", ".css", ".js", ".json") or path.name in ("_headers", "_redirects"):
            shutil.copy2(path, output / path.name)
    subprocess.run([sys.executable, str(ROOT / "Scripts/changelog.py"), "--write",
                    "--output", str(output / "changelog.html")], check=True)
    shutil.copytree(SOURCE / "assets", output / "assets", ignore=shutil.ignore_patterns(".DS_Store"))
    for suffix in ("", "-dark"):
        with Image.open(BRANDING / f"FoldGit{suffix}.webp") as image:
            source = image.convert("RGBA")
        source.resize((180, 180), Image.Resampling.LANCZOS).save(
            output / f"assets/favicon{suffix}.png", optimize=True
        )
        source.resize((512, 512), Image.Resampling.LANCZOS).save(
            output / f"assets/icon{suffix}.webp", quality=90, method=6, alpha_quality=100
        )
    screenshots = output / "assets/screenshots"
    for language in ("zh", "en"):
        for scheme in ("light", "dark"):
            name = f"main-{language}-{scheme}"
            with Image.open(screenshots / f"{name}@2x.webp") as image:
                if image.size != (3840, 1976):
                    raise ValueError(f"{name}@2x.webp must be 3840 × 1976 pixels")
                image.resize((1920, 988), Image.Resampling.LANCZOS).save(
                    screenshots / f"{name}.webp", quality=90, method=6
                )
    print(f"Built website in {output}")


if __name__ == "__main__":
    build(OUTPUT)
