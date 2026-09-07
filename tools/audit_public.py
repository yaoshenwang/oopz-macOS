#!/usr/bin/env python3
"""Fail closed on common publication mistakes; never print matched values.

Local reviewers can provide additional private strings in an OUTSIDE-repository JSON array
through OOPZ_AUDIT_DENYLIST. That file and its contents must never be uploaded.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_EXTENSIONS = {'.pem', '.key', '.der', '.p8', '.p12', '.pfx', '.har', '.pcap', '.pcapng', '.jsonl'}
PRIVATE_DIRS = {'research', 'captures', '.private', 'accounts', 'node_modules', 'Vendor', '.build', 'build'}
PATTERNS = {
    'absolute-home-path': re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----'),
    'jwt': re.compile(rb'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
    'service-token': re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16})'),
    'personal-email': re.compile(rb'[A-Za-z0-9_.+-]+@(?!users\.noreply\.github\.com\b|example\.(?:com|invalid)\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
}

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], stderr=subprocess.DEVNULL)

def source_paths():
    return sorted(set(filter(None, git('ls-files', '-z', '--cached', '--others', '--exclude-standard').decode().split('\0'))))

def extra_terms():
    value = os.environ.get('OOPZ_AUDIT_DENYLIST')
    if not value: return []
    path = Path(value).expanduser().resolve()
    if path.is_relative_to(ROOT): raise ValueError('Private denylist must be outside the repository')
    terms = json.loads(path.read_text())
    if not isinstance(terms, list) or any(not isinstance(x, str) or len(x) < 2 for x in terms):
        raise ValueError('Invalid private denylist')
    return [x.lower().encode() for x in terms]

def inspect_bytes(data, terms=(), *, binary=False):
    hits = [name for name, pattern in PATTERNS.items() if pattern.search(data)]
    if any(term in data.lower() for term in terms): hits.append('private-local-denylist')
    if not binary:
        # Also catch private keys split across adjacent base64 Swift/JS string literals.
        fragments = re.findall(rb'["\x27]([A-Za-z0-9+/=]{20,})["\x27]', data)
        joined = b''.join(fragments)
        if re.search(rb'MII[A-Za-z0-9+/]{500,}', joined): hits.append('encoded-key-material')
    return hits

def inspect_path(name):
    p = Path(name)
    if p.suffix.lower() in PRIVATE_EXTENSIONS or set(p.parts) & PRIVATE_DIRS:
        return ['private-file-type']
    if p.name in {'session.json', '.env', 'hosts.yml'} or p.name.startswith('.env.'):
        return ['private-config']
    return []

def filter_vendor_metadata(data, hits, entry):
    # Only byte-identical upstream files may carry upstream attribution/build paths.
    # A filename alone never grants an exception, and secrets/denylist always fail.
    if entry and hashlib.sha256(data).hexdigest() == entry.get('sha256'):
        allowed = set(entry.get('upstream_metadata', [])) & {'absolute-home-path', 'personal-email'}
        return [hit for hit in hits if hit not in allowed]
    return hits

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--history', action='store_true')
    parser.add_argument('--staged', action='store_true')
    parser.add_argument('--artifact', type=Path)
    args = parser.parse_args()
    terms, failures, count = extra_terms(), [], 0
    if args.artifact:
        root = args.artifact.resolve()
        vendor = json.loads((ROOT / 'tools/vendor_metadata.json').read_text())['files']
        if not root.is_dir(): raise SystemExit('Artifact must be an unpacked application directory')
        for path in root.rglob('*'):
            if path.is_symlink():
                if not path.resolve().is_relative_to(root): failures.append((str(path.relative_to(root)), ['external-symlink']))
                continue
            if not path.is_file(): continue
            count += 1
            data = path.read_bytes()
            hits = filter_vendor_metadata(data, inspect_bytes(data, terms, binary=True), vendor.get(str(path.relative_to(root))))
            if path.suffix in PRIVATE_EXTENSIONS or path.name == 'session.json': hits.append('private-file-type')
            if hits: failures.append((str(path.relative_to(root)), hits))
    else:
        paths = source_paths() if not args.staged else list(filter(None, git('ls-files', '-z').decode().split('\0')))
        for name in paths:
            path = ROOT / name
            hits = inspect_path(name) + inspect_bytes(name.encode(), terms)
            if args.staged:
                data = git('show', ':' + name)
                mode = git('ls-files', '-s', '--', name).decode().split()[0]
                if mode == '120000': hits.append('source-symlink')
            else:
                if path.is_symlink(): hits.append('source-symlink'); data = os.readlink(path).encode()
                elif path.is_file(): data = path.read_bytes()
                else: failures.append((name, ['missing-file'])); continue
            count += 1
            hits += inspect_bytes(data, terms)
            if len(data) > 1_000_000: hits.append('unexpected-large-source')
            if hits: failures.append((name, hits))
        if args.history:
            commits = git('rev-list', '--all').decode().split()
            checked = set()
            for commit in commits:
                meta = git('show', '-s', '--format=%an%n%ae%n%cn%n%ce%n%B', commit)
                hits = inspect_bytes(meta, terms)
                if hits: failures.append((commit[:8] + ':metadata', hits))
                for entry in git('ls-tree', '-rz', commit).split(b'\0'):
                    if not entry: continue
                    header, name = entry.split(b'\t', 1)
                    mode, kind, sha = header.split()
                    if kind != b'blob': failures.append((name.decode(), ['unexpected-git-object'])); continue
                    pathhits = inspect_path(name.decode()) + inspect_bytes(name, terms)
                    if mode == b'120000': pathhits.append('source-symlink')
                    if pathhits: failures.append((commit[:8] + ':' + name.decode(), pathhits))
                    if sha in checked: continue
                    checked.add(sha); count += 1
                    hits = inspect_bytes(git('cat-file', 'blob', sha.decode()), terms)
                    if hits: failures.append((commit[:8] + ':' + name.decode(), hits))
    for path, reasons in failures:
        # File locations only, never the matching line, bytes, author, or private value.
        print('FAIL:', path, ','.join(sorted(set(reasons))))
    if failures: raise SystemExit(1)
    print(f'PASS: publication audit ({count} objects; no detected prohibited data)')

if __name__ == '__main__': main()
