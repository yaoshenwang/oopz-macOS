#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=
python3 tools/fetch_dependencies.py
swift package resolve
python3 tools/generate_assets.py
swift tools/generate_icon.swift Resources/AppIcon.icns
echo 'PASS: dependencies and original resources prepared'
