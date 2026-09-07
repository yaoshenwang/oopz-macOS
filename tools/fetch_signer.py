#!/usr/bin/env python3
"""Install a checksum-pinned rcodesign; no credentials are read during download."""
import hashlib
import io
import platform
from pathlib import Path
import tarfile
import urllib.request

VERSION = '0.29.0'
ARCHIVES = {
    'arm64': ('aarch64', 'd1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a'),
    'x86_64': ('x86_64', '14ef11bedd51a8d95eafd767939ae96d5900e5a61511bef75bb21db6e7c74140'),
}

def signer_path(download=False):
    arch, digest = ARCHIVES[platform.machine()]
    folder = Path.home() / 'Library/Caches/OopzBuild' / f'rcodesign-{VERSION}-{arch}'
    archive = folder / 'release.tar.gz'
    if not archive.exists():
        if not download:
            raise SystemExit('签名工具未准备好：先运行 python3 tools/fetch_signer.py')
        url = f'https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/{VERSION}/apple-codesign-{VERSION}-{arch}-apple-darwin.tar.gz'
        data = urllib.request.urlopen(url, timeout=60).read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit('签名工具下载校验失败')
        folder.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(data)
    data = archive.read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit('签名工具缓存校验失败，请删除该缓存后重新下载')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as bundle:
        member = next(m for m in bundle.getmembers() if Path(m.name).name == 'rcodesign' and m.isfile())
        binary = bundle.extractfile(member).read()
    target = folder / 'rcodesign'
    if not target.exists() or hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(binary).digest():
        target.write_bytes(binary)
        target.chmod(0o755)
    return target

if __name__ == '__main__':
    print(signer_path(download=True))
