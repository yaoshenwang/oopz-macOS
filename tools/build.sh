#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=${1:---compile}
case "$MODE" in --compile|--assemble|--local) ;; *) echo 'Usage: tools/build.sh [--compile|--assemble|--local]' >&2; exit 2;; esac
python3 tools/audit_public.py
ROOT=$(pwd -P)
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=
FLAGS=(-Xswiftc -gnone -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/src/oopz-macOS" -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/src/oopz-macOS")
if [ "$MODE" = --compile ]; then
  swift build --disable-automatic-resolution -c release "${FLAGS[@]}"
  exit 0
fi
python3 tools/manifest.py snapshot .build/source-before.json
for ARCH in arm64 x86_64; do
  swift package --scratch-path ".build/universal/$ARCH" resolve
  swift build --scratch-path ".build/universal/$ARCH" --disable-automatic-resolution -c release --arch "$ARCH" "${FLAGS[@]}"
done
python3 tools/manifest.py unchanged .build/source-before.json
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
APP="build/$VER/Oopz.app"
mkdir -p "build/$VER"
if [ -e "build/$VER/release.json" ]; then echo 'Released version is immutable; bump the version.' >&2; exit 2; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/sounds"
python3 tools/check_resources.py
lipo -create .build/universal/arm64/arm64-apple-macosx/release/Oopz .build/universal/x86_64/x86_64-apple-macosx/release/Oopz -output "$APP/Contents/MacOS/Oopz"
lipo "$APP/Contents/MacOS/Oopz" -verify_arch arm64 x86_64
strip -S "$APP/Contents/MacOS/Oopz"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
python3 - "$APP" <<'PY'
from pathlib import Path
import json, shutil, sys
for name in json.loads(Path('Resources/manifest.json').read_text())['files']:
    shutil.copyfile(Path('Resources') / name, Path(sys.argv[1]) / 'Contents/Resources' / name)
PY
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
python3 tools/assemble_frameworks.py "$APP"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Oopz"
xattr -cr "$APP"
python3 tools/manifest.py record "$APP" .build/source-before.json
python3 tools/audit_public.py --artifact "$APP"
if [ "$MODE" = --local ]; then
  python3 tools/fetch_signer.py >/dev/null
  python3 tools/sign_local.py "$APP"
  python3 tools/manifest.py signed "$APP"
fi
ln -sfn "$VER" build/latest
echo "PASS: build/$VER/Oopz.app ($MODE); not a notarized public release"
