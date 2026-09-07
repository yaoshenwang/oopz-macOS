#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/audit_public.py --history
if [ -n "$(git status --porcelain)" ]; then echo 'Commit the reviewed source before export.' >&2; exit 2; fi
mkdir -p .build/exports
git archive --format=zip --prefix=oopz-macOS/ -o .build/exports/oopz-macOS-source.zip HEAD
echo 'PASS: source-only archive created under .build/exports; no Git identity metadata or ignored files included'
