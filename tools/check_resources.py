#!/usr/bin/env python3
"""Verify the exact official assets used by both source and assembled applications."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main():
    base = ROOT / 'Resources'
    files = json.loads((base / 'manifest.json').read_text())['files']
    expected = {'AppIcon.icns'} | {'sounds/' + name + '.wav' for name in (
        'cancel_headset_mute', 'cancel_microphone_mute', 'enter_voice', 'exit_voice',
        'headset_mute', 'microphone_mute', 'person_enter_voice', 'person_exit_voice')}
    if set(files) != expected:
        raise SystemExit('FAIL: official resource manifest has unexpected entries')
    for name, digest in files.items():
        path = base / name
        if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit('FAIL: official resource missing or modified: ' + name)
    print('PASS: official icon and eight notification sounds match their manifest')

if __name__ == '__main__': main()
