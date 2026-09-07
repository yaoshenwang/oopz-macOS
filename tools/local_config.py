#!/usr/bin/env python3
"""Read an explicit outside-repository file, never a Keychain or ambient credential store."""
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def load():
    location = os.environ.get('OOPZ_SIGNING_CONFIG')
    if not location: raise SystemExit('Set OOPZ_SIGNING_CONFIG to an outside-repository JSON file; see docs/RELEASING.md')
    path = Path(location).expanduser().resolve()
    if path.is_relative_to(ROOT) or not path.is_file() or path.stat().st_mode & 0o077:
        raise SystemExit('Signing configuration must be an outside-repository file readable only by its owner')
    return json.loads(path.read_text())

def file(config, name, private=True):
    value = config.get(name)
    if not isinstance(value, str) or not value: raise SystemExit('Missing configuration field: ' + name)
    path = Path(value).expanduser().resolve()
    if path.is_relative_to(ROOT) or not path.is_file(): raise SystemExit('Invalid external file: ' + name)
    if private and path.stat().st_mode & 0o077: raise SystemExit('Private file permissions must be 0600: ' + name)
    return path
