#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/audit_public.py --history
exec python3 tools/release.py "$@"
