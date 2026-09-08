#!/usr/bin/env python3
"""Publish exact verified assets; reruns never overwrite a public version."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from build_channel import channel
from audit_public import inspect_bytes

def run(args, **kwargs): return subprocess.run(args, check=True, **kwargs)
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def validate(folder, tag, commit, *, allow_dev=False):
    match = re.match(r'^v(\d+\.\d+\.\d+)(?:-|$)', tag)
    if not match: raise ValueError('Invalid version tag')
    selected_channel = channel(tag, match[1], commit)
    if selected_channel == 'dev' and not allow_dev:
        raise ValueError('Dev builds must never be published as GitHub Releases')
    version = tag[1:]
    expected = {f'Oopz-{version}-universal.dmg', f'Oopz-{version}-universal.zip', 'release.json', 'SHA256SUMS', 'RELEASE_NOTES.md'}
    if {p.name for p in folder.iterdir()} != expected or any(p.is_symlink() or not p.is_file() for p in folder.iterdir()):
        raise ValueError('Unexpected release files')
    metadata = json.loads((folder / 'release.json').read_text())
    if metadata.get('channel', 'stable') != selected_channel:
        raise ValueError('Distribution channel mismatch')
    for name in ('release.json', 'SHA256SUMS', 'RELEASE_NOTES.md'):
        if inspect_bytes((folder / name).read_bytes()):
            raise ValueError('Prohibited data in distribution metadata')
    if metadata.get('version') != version or metadata.get('sourceCommit') != commit or metadata.get('notarized') is not True or metadata.get('signing') != 'Developer ID':
        raise ValueError('Release manifest does not match the signed version')
    files = {p.name: sha(p) for p in folder.iterdir() if p.name not in ('SHA256SUMS', 'RELEASE_NOTES.md')}
    if (folder / 'SHA256SUMS').read_text() != ''.join(f'{digest}  {name}\n' for name, digest in sorted(files.items())):
        raise ValueError('Release checksum mismatch')
    if metadata['files'] != {k: v for k, v in files.items() if k != 'release.json'}: raise ValueError('Asset digest mismatch')
    return sorted(expected - {'RELEASE_NOTES.md'})

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--repository', required=True)
    p.add_argument('--tag', required=True)
    p.add_argument('--commit', required=True)
    p.add_argument('--directory', type=Path, required=True)
    args = p.parse_args()
    names = validate(args.directory, args.tag, args.commit)
    base = ['--repo', args.repository]
    existing = subprocess.run(['gh', 'release', 'view', args.tag, *base, '--json', 'isDraft,assets'], capture_output=True, text=True)
    if existing.returncode == 0:
        data = json.loads(existing.stdout)
        remote_names = {a['name'] for a in data['assets']}
        if not remote_names <= set(names): raise ValueError('Remote release has unexpected assets; refusing overwrite')
        with tempfile.TemporaryDirectory(prefix='oopz-release-check-') as tmp:
            for name in sorted(remote_names):
                run(['gh', 'release', 'download', args.tag, *base, '--pattern', name, '--dir', tmp])
                if sha(Path(tmp) / name) != sha(args.directory / name): raise ValueError('Remote asset differs; never overwrite a released version')
        if not data['isDraft']:
            if remote_names != set(names): raise ValueError('Published release is incomplete; refusing mutation')
            print('PASS: identical release already published'); return
    else:
        run(['gh', 'release', 'create', args.tag, *base, '--verify-tag', '--draft', '--title', 'Oopz ' + args.tag[1:],
             '--notes-file', str(args.directory / 'RELEASE_NOTES.md')])
        remote_names = set()
    missing = [str(args.directory / name) for name in names if name not in remote_names]
    if missing: run(['gh', 'release', 'upload', args.tag, *base, *missing])
    run(['gh', 'release', 'edit', args.tag, *base, '--draft=false', '--latest'])
    print('PASS: notarized DMG, ZIP, checksums and manifest published')

if __name__ == '__main__': main()
