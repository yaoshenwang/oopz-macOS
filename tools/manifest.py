#!/usr/bin/env python3
"""Bind a build to its source snapshot and complete application payload."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from audit_public import ROOT, source_paths

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def snapshot():
    files = {p: sha(ROOT / p) for p in source_paths()}
    try: commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL).decode().strip()
    except subprocess.CalledProcessError: commit = None
    dirty = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain']))
    return {'commit': commit, 'dirty': dirty, 'files': files}

def tree(app):
    result = {}
    for p in sorted(app.rglob('*')):
        if p.is_symlink(): result[str(p.relative_to(app))] = 'symlink:' + p.readlink().as_posix()
        elif p.is_file(): result[str(p.relative_to(app))] = sha(p)
    return result

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')

def main():
    command = sys.argv[1]
    if command == 'snapshot': write(Path(sys.argv[2]), snapshot())
    elif command == 'unchanged':
        if snapshot() != json.loads(Path(sys.argv[2]).read_text()): raise SystemExit('Source changed during build')
    elif command == 'record':
        app = Path(sys.argv[2]); source = json.loads(Path(sys.argv[3]).read_text())
        if source != snapshot(): raise SystemExit('Source changed during assembly')
        write(app.parent / 'build.json', {'source': source, 'signing': 'unpublished-assembly', 'files': tree(app)})
    elif command == 'signed':
        app = Path(sys.argv[2]); record = json.loads((app.parent / 'build.json').read_text())
        record.update({'signing': 'local-developer-id', 'files': tree(app)})
        write(app.parent / 'build.json', record)
    else: raise SystemExit('Unknown manifest operation')

if __name__ == '__main__': main()
