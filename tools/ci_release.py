#!/usr/bin/env python3
"""Separate credential-free assembly from ephemeral Developer ID signing/publication."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
from audit_public import ROOT
from manifest import snapshot, tree, write
from build_channel import channel

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def validate_tag(tag, version):
    return channel(tag, version)

def validate_archive(path):
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or '..' in name.parts or not name.parts or name.parts[0] not in ('Oopz.app', 'build.json'):
                raise ValueError('Unexpected archive path')
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = PurePosixPath(archive.read(entry).decode())
                if target.is_absolute() or '..' in target.parts: raise ValueError('Unsafe archive symlink')

def prepare(tag):
    version = plistlib.loads((ROOT / 'Info.plist').read_bytes())['CFBundleShortVersionString']
    validate_tag(tag, version)
    app = ROOT / 'build' / version / 'Oopz.app'
    record = json.loads((app.parent / 'build.json').read_text())
    if record['signing'] != 'unpublished-assembly' or record['source'] != snapshot() or record['source']['dirty']:
        raise ValueError('Prepare requires a clean matching unsigned build')
    if record['files'] != tree(app): raise ValueError('Assembly changed after build')
    run(['python3', ROOT / 'tools/audit_public.py', '--artifact', app])
    output = ROOT / '.build/release-input'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='oopz-package-') as tmp:
        folder = Path(tmp)
        shutil.copytree(app, folder / 'Oopz.app', symlinks=True)
        shutil.copyfile(app.parent / 'build.json', folder / 'build.json')
        archive = output / 'unsigned.zip'
        archive.unlink(missing_ok=True)
        run(['ditto', '-c', '-k', '--norsrc', folder, archive])
        validate_archive(archive)
    (output / 'SHA256SUMS').write_text(sha(archive) + '  unsigned.zip\n')
    print('PASS: audited unsigned payload prepared; no signing credentials used')

def verify_signed(app, team, log):
    requirement = ('identifier "cn.oopz.mac" and anchor apple generic and '
                   'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
                   'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                   f'certificate leaf[subject.OU] = "{team}"')
    run(['lipo', app / 'Contents/MacOS/Oopz', '-verify_arch', 'arm64', 'x86_64'], stdout=log, stderr=log)
    for arch in ('arm64', 'x86_64'):
        run(['codesign', '--verify', '--deep', '--strict', '--arch', arch, '-R', '=' + requirement, app], stdout=log, stderr=log)

def sign(tag, source_commit, input_dir, output):
    from fetch_signer import signer_path
    from release import notarize
    signer = signer_path(False)  # Downloaded and checksum-verified in an earlier step.
    base_version = plistlib.loads((ROOT / 'Info.plist').read_bytes())['CFBundleShortVersionString']
    selected_channel = channel(tag, base_version, source_commit)
    archive = input_dir / 'unsigned.zip'
    if (input_dir / 'SHA256SUMS').read_text() != sha(archive) + '  unsigned.zip\n':
        raise ValueError('Unsigned payload checksum mismatch')
    validate_archive(archive)
    if output.exists() and any(output.iterdir()): raise ValueError('Distribution output must be empty')
    output.mkdir(parents=True, exist_ok=True)
    # Outside checkout; files are never put into Actions artifacts or cache.
    with tempfile.TemporaryDirectory(prefix='oopz-sign-') as tmp:
        folder = Path(tmp); folder.chmod(0o700)
        log_path = folder / 'signing.log'
        payload = folder / 'payload'
        run(['ditto', '-x', '-k', archive, payload])
        app = payload / 'Oopz.app'
        record = json.loads((payload / 'build.json').read_text())
        if record['source']['commit'] != source_commit or record['source']['dirty'] or record['signing'] != 'unpublished-assembly':
            raise ValueError('Build does not belong to this release commit')
        if record['files'] != tree(app): raise ValueError('Downloaded assembly differs from build record')
        run(['python3', ROOT / 'tools/audit_public.py', '--artifact', app],
            env={k: v for k, v in os.environ.items() if not k.startswith(('MACOS_', 'NOTARY_'))})
        info_path = app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        if info['CFBundleShortVersionString'] != base_version:
            raise ValueError('Assembly version differs from the source version')
        if selected_channel == 'dev':
            # Preserve the numeric Apple version and identity/TCC/session continuity.
            # Only the distribution copy is stamped; source Info.plist is unchanged.
            info['CFBundleDisplayName'] = 'Oopz Dev'
            info['OopzBuildChannel'] = 'dev'
            info['OopzBuildIdentifier'] = tag[1:]
            info_path.write_bytes(plistlib.dumps(info))
        config = {}
        for field, variable, filename in [
            ('private_key', 'MACOS_SIGNING_KEY', 'identity.key'),
            ('certificate_chain', 'MACOS_CERTIFICATE_CHAIN', 'chain.pem'),
            ('notary_key', 'NOTARY_KEY', 'notary.p8')]:
            value = os.environ.pop(variable, '')
            if not value: raise ValueError('Required release credential is missing: ' + variable)
            path = folder / filename
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream: stream.write(value)
            config[field] = str(path)
        for field, variable in [('team_id', 'MACOS_TEAM_ID'), ('notary_key_id', 'NOTARY_KEY_ID'), ('notary_issuer', 'NOTARY_ISSUER')]:
            config[field] = os.environ.pop(variable, '')
            if not config[field]: raise ValueError('Required release identity is missing')
        if not re.fullmatch(r'[A-Z0-9]{10}', config['team_id']): raise ValueError('Invalid signing team')
        profile = '(version 1)(allow default)(deny mach-lookup (global-name "com.apple.securityd"))(deny file-read* (regex #"/Library/Keychains(/|$)"))'
        with log_path.open('wb') as log:
            log_path.chmod(0o600)
            run(['sandbox-exec', '-p', profile, signer, '--config-file', '/dev/null', 'sign', '--for-notarization',
                 '--pem-file', config['certificate_chain'], '--pem-file', config['private_key'],
                 '--entitlements-xml-file', ROOT / 'entitlements.plist', app], stdout=log, stderr=log, timeout=180)
            verify_signed(app, config['team_id'], log)
            notarization_zip = folder / 'notarization.zip'
            run(['ditto', '-c', '-k', '--keepParent', '--norsrc', app, notarization_zip], stdout=log, stderr=log)
            print('Developer ID verified; submitting application for notarization', flush=True)
            notarize(notarization_zip, config, folder / 'app-notary.json', log, timeout=2400)
            run(['xcrun', 'stapler', 'staple', app], stdout=log, stderr=log)
            run(['xcrun', 'stapler', 'validate', app], stdout=log, stderr=log)
            verify_signed(app, config['team_id'], log)
            run(['spctl', '-a', '-t', 'exec', app], stdout=log, stderr=log)
            # The executable runs only after private files have been removed, without credentials.
            for field in ('private_key', 'certificate_chain'):
                Path(config[field]).unlink()
            version = tag[1:]
            dmg = output / f'Oopz-{version}-universal.dmg'
            zipped = output / f'Oopz-{version}-universal.zip'
            image_folder = folder / 'disk'
            image_folder.mkdir()
            shutil.copytree(app, image_folder / 'Oopz.app', symlinks=True)
            (image_folder / 'Applications').symlink_to('/Applications')
            run(['hdiutil', 'create', '-volname', 'Oopz', '-srcfolder', image_folder, '-format', 'UDZO', dmg], stdout=log, stderr=log)
            print('Application notarized; submitting DMG for notarization', flush=True)
            notarize(dmg, config, folder / 'dmg-notary.json', log, timeout=2400)
            run(['xcrun', 'stapler', 'staple', dmg], stdout=log, stderr=log)
            run(['xcrun', 'stapler', 'validate', dmg], stdout=log, stderr=log)
            Path(config['notary_key']).unlink()
            # Inspect the actual mounted installer, not just the staging application.
            mount = folder / 'mounted'; mount.mkdir()
            run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg], stdout=log, stderr=log)
            try:
                installed = mount / 'Oopz.app'
                if tree(installed) != tree(app): raise ValueError('Mounted DMG payload changed')
                verify_signed(installed, config['team_id'], log)
                run(['xcrun', 'stapler', 'validate', installed], stdout=log, stderr=log)
                env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR')}
                env['OOPZ_DATA_DIR'] = str(folder / 'runtime')
                runtime_profile = profile + '(deny network*)'
                run(['sandbox-exec', '-p', runtime_profile, installed / 'Contents/MacOS/Oopz', '--help'], env=env, stdout=log, stderr=log, timeout=30)
            finally:
                run(['hdiutil', 'detach', mount], stdout=log, stderr=log)
            run(['ditto', '-c', '-k', '--keepParent', '--norsrc', app, zipped], stdout=log, stderr=log)
        files = {p.name: sha(p) for p in (dmg, zipped)}
        write(output / 'release.json', {'version': version, 'sourceCommit': source_commit,
              'baseVersion': base_version, 'channel': selected_channel,
              'signing': 'Developer ID', 'notarized': True, 'architectures': ['arm64', 'x86_64'],
              'validation': 'offline checks, signatures, notarization, mounted installer and headless launch',
              'officialWebAcceptance': 'manual', 'files': files})
        files['release.json'] = sha(output / 'release.json')
        (output / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(files.items())))
        (output / 'RELEASE_NOTES.md').write_text(
            f'# Oopz {version}\n\nmacOS 14+ · Apple Silicon / Intel universal\n\n'
            + ('Dev 内测构建，不是正式 Release。与正式版共用应用身份及本机数据，请替换安装、不要同时运行。\n\n' if selected_channel == 'dev' else '') +
            '下载 DMG，将 Oopz 拖入 Applications；也可下载 ZIP 解压安装。\n\n'
            '安装包已完成 Developer ID 签名和 Apple 公证。官方图标与提示音原样保留。\n\n'
            '自动检查包含离线回归、双架构签名、公证票据、DMG 挂载和无头启动。'
            '真实首次登录、官方 Web 共享画面和听感属于人工验收范围，自动构建不代表这些项目已经通过。\n\n'
            f'源码提交：`{source_commit}`。完整性校验见 SHA256SUMS。\n')
        from publish_release import validate
        validate(output, tag, source_commit, allow_dev=True)
    print('PASS: signed and notarized DMG/ZIP verified; credential files removed')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['prepare', 'sign'])
    p.add_argument('--tag', required=True)
    p.add_argument('--commit')
    p.add_argument('--input', type=Path)
    p.add_argument('--output', type=Path)
    args = p.parse_args()
    if args.command == 'prepare': prepare(args.tag)
    else:
        if not args.commit or not re.fullmatch(r'[a-f0-9]{40}', args.commit) or not args.input or not args.output:
            raise ValueError('Sign requires commit, input and output')
        sign(args.tag, args.commit, args.input.resolve(), args.output.resolve())

if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        raise SystemExit('Release failed: packaging, signature, notarization or installer validation failed. No credentials or private logs were uploaded.')
