#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1])
names = json.loads((root / 'tools/dependencies.json').read_text())['frameworks']
sources = []
for name in names:
    matches = list((root / 'Vendor' / (name + '.xcframework')).glob('macos*/*.framework'))
    if len(matches) != 1: raise SystemExit('Expected one macOS framework: ' + name)
    sources += matches
infra = list((root / '.build/artifacts').glob('**/macos*/aosl.framework'))
if len(infra) != 1: raise SystemExit('Expected one pinned macOS aosl framework')
for source in sources + infra:
    shutil.copytree(source, app / 'Contents/Frameworks' / source.name, symlinks=True)
