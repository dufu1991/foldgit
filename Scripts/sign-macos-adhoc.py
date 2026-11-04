#!/usr/bin/env python3
"""Sign an ad hoc distribution, including embedded Sparkle executables, inside out."""

from pathlib import Path
import argparse
import subprocess


def sign(app):
    # Hardened library validation requires Apple identities for embedded frameworks.
    # Ad hoc distributions use structural signatures without hardened runtime.
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    files = []
    bundles = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {".app", ".xpc", ".framework"}:
            bundles.append(path)
        if path.is_file():
            with path.open("rb") as source:
                if source.read(4) in magic:
                    files.append(path)
    for path in files + sorted(bundles, key=lambda path: len(path.parts), reverse=True) + [app]:
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                        "--preserve-metadata=entitlements", str(path)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    sign(parser.parse_args().app.resolve())
