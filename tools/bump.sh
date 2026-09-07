#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-patch}" <<'PY'
from pathlib import Path
import plistlib, sys
path = Path('Info.plist'); data = plistlib.loads(path.read_bytes())
old = data['CFBundleShortVersionString']; parts = list(map(int, old.split('.')))
index = {'major': 0, 'minor': 1, 'patch': 2}.get(sys.argv[1])
if index is None: raise SystemExit('Usage: tools/bump.sh [patch|minor|major]')
parts[index] += 1
for i in range(index + 1, 3): parts[i] = 0
version = '.'.join(map(str, parts))
if (Path('build') / version).exists(): raise SystemExit('Version already built; refusing reuse')
data['CFBundleShortVersionString'] = version
data['CFBundleVersion'] = str(int(data['CFBundleVersion']) + 1)
path.write_bytes(plistlib.dumps(data))
print(old + ' -> ' + version + '; update CHANGELOG.md and commit before release verification')
PY
