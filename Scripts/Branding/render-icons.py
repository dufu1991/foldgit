#!/usr/bin/env python3
"""Export portable brand images from the canonical Icon Composer document."""

import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BRANDING = ROOT / 'Shared/Resources/Branding'
ICON = BRANDING / 'AppIcon.icon'
TOOL = Path('/Applications/Icon Composer.app/Contents/Executables/ictool')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--previews', type=Path, default=ROOT / 'output/FoldGit-icon-final/previews')
arguments = parser.parse_args()
arguments.previews.mkdir(parents=True, exist_ok=True)
(BRANDING / 'Images').mkdir(exist_ok=True)

for mode in ['Default', 'Dark', 'ClearLight', 'ClearDark', 'TintedLight', 'TintedDark']:
    destination = arguments.previews / f'{mode}.png'
    command = [str(TOOL), str(ICON), '--export-image', '--output-file', str(destination),
               '--platform', 'macOS', '--rendition', mode, '--width', '1024',
               '--height', '1024', '--scale', '1']
    if mode.startswith('Tinted'):
        command += ['--tint-color', '0.72', '--tint-strength', '0.55']
    subprocess.run(command, check=True, capture_output=True)
    if mode in ['Default', 'Dark']:
        filename = 'FoldGit.png' if mode == 'Default' else 'FoldGit-dark.png'
        (BRANDING / 'Images' / filename).write_bytes(destination.read_bytes())
    print(destination)
