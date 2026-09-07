#!/usr/bin/env python3
"""Download only pinned SDK archives. Check bytes before extracting, including cache hits."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def download(url, pending):
    request = urllib.request.Request(url, method='HEAD')
    with urllib.request.urlopen(request, timeout=30) as response:
        size = int(response.headers.get('Content-Length', '0'))
        ranges = response.headers.get('Accept-Ranges', '') == 'bytes'
    if size >= 8_000_000 and ranges:
        parts = pending.parent / (pending.stem + '.parts')
        parts.mkdir(exist_ok=True)
        chunk = 4_000_000
        def fetch(index):
            start, end = index * chunk, min((index + 1) * chunk, size) - 1
            target = parts / str(index)
            if target.exists() and target.stat().st_size == end - start + 1: return target
            for attempt in range(3):
                response_file = target.with_suffix('.headers')
                result = subprocess.run(['curl', '--fail', '--location', '--range', f'{start}-{end}',
                    '--connect-timeout', '20', '--max-time', '240', '--silent', '--show-error',
                    '--dump-header', str(response_file), '--output', str(target), url], stderr=subprocess.DEVNULL)
                expected = f'content-range: bytes {start}-{end}/{size}'
                headers = response_file.read_text().lower() if response_file.exists() else ''
                if result.returncode == 0 and target.stat().st_size == end - start + 1 and expected in headers:
                    return target
            raise ValueError('SDK range download failed')
        with ThreadPoolExecutor(max_workers=6) as pool:
            files = list(pool.map(fetch, range((size + chunk - 1) // chunk)))
        with pending.open('wb') as output:
            for part in files:
                with part.open('rb') as stream: shutil.copyfileobj(stream, output)
        shutil.rmtree(parts)
        return
    for attempt in range(8):
        result = subprocess.run(['curl', '--fail', '--location', '--connect-timeout', '20', '--continue-at', '-',
                                 '--max-time', '120', '--silent', '--show-error', '--output', str(pending), url], stderr=subprocess.DEVNULL)
        if result.returncode == 0: return
        if result.returncode == 33: pending.unlink(missing_ok=True)
        print('Retrying SDK download with partial bytes preserved', flush=True)
    raise ValueError('SDK download failed')

def safe_members(archive):
    for item in archive.infolist():
        path = Path(item.filename)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Unsafe SDK archive member')

def main():
    manifest = json.loads((ROOT / 'tools/dependencies.json').read_text())
    vendor = ROOT / 'Vendor'
    vendor.mkdir(exist_ok=True)
    lock = (vendor / '.download.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('Another SDK preparation is running')
    cache = Path(os.environ.get('OOPZ_SDK_CACHE_DIR', str(vendor / '.archives'))).expanduser()
    cache.mkdir(parents=True, exist_ok=True)
    cache_lock = (cache / '.lock').open('w')
    try: fcntl.flock(cache_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('Another SDK download is using this archive cache')
    def prepare(entry):
        name, item = entry
        archive = cache / (name + '.zip')
        def valid():
            return archive.is_file() and hashlib.sha256(archive.read_bytes()).hexdigest() == item['sha256']
        if not valid():
            pending = archive.with_suffix('.partial')
            print('Downloading verified SDK: ' + name, flush=True)
            download(item['url'], pending)
            if hashlib.sha256(pending.read_bytes()).hexdigest() != item['sha256']:
                pending.unlink(missing_ok=True)
                raise SystemExit('SDK checksum mismatch: ' + name)
            pending.replace(archive)
        with zipfile.ZipFile(archive) as z:
            safe_members(z)
        # ditto preserves framework symlinks. Always re-extract validated bytes, not a trusted-directory flag.
        with tempfile.TemporaryDirectory(prefix='.sdk-', dir=vendor) as tmp:
            subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), tmp], check=True)
            source = Path(tmp) / (name + '.xcframework')
            if not (source / 'Info.plist').is_file():
                raise SystemExit('Missing framework: ' + name)
            dest = vendor / source.name
            if dest.exists(): shutil.rmtree(dest)
            source.rename(dest)
        print('PASS: verified SDK ' + name)
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(prepare, manifest['frameworks'].items()))

if __name__ == '__main__': main()
