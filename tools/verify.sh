#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MEDIA=0
REUSE=0
for ARG in "$@"; do
  case "$ARG" in --media) MEDIA=1;; --existing) REUSE=1;; *) echo 'Usage: tools/verify.sh [--media] [--existing]'; exit 2;; esac
done
./tools/check_fast.sh
pkill -f 'MacOS/Oopz' 2>/dev/null || true
if [ "$REUSE" = 0 ]; then ./tools/build.sh --local; fi
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
export OOPZ_TEST_RESULTS
OOPZ_TEST_RESULTS=$(mktemp -d "/tmp/oopz-verify-$VER.XXXXXX")
chmod 700 "$OOPZ_TEST_RESULTS"
unset OOPZ_ALLOW_AUDIO_INJECT
python3 tools/run_checks.py "build/$VER/Oopz.app/Contents/MacOS/Oopz" "$MEDIA"
echo 'PASS: local integration; official Web picture and physical audio remain manual checks'
