#!/usr/bin/env python3
"""Release only the reviewed, tested application. No compilation and no Keychain access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
from local_config import load, file, ROOT
from manifest import tree, snapshot, write

def validate_receipts(build, validation, current_files, current_source, acceptance):
    if not build['source'].get('commit') or build['source'].get('dirty'):
        raise ValueError('Release requires a clean committed source build')
    if build['source'] != current_source: raise ValueError('Checkout differs from built source')
    if build['signing'] != 'local-developer-id': raise ValueError('Maintainer signature missing')
    if build['files'] != current_files or validation.get('files') != current_files:
        raise ValueError('Application changed after build or validation')
    if validation.get('pass') is not True or validation.get('sourceCommit') != build['source']['commit']:
        raise ValueError('Local validation is missing or mismatched')
    steps = {x['mode']: x.get('pass') for x in validation.get('steps', [])}
    if steps.get('--smoke') is not True or steps.get('--media-test') is not True:
        raise ValueError('Protocol and publisher checks must both pass for this release')
    if acceptance.get('sourceCommit') != build['source']['commit'] or acceptance.get('sha256') != validation.get('sha256'):
        raise ValueError('Manual acceptance must identify the tested commit and binary')
    required = ['fullscreen', 'stop', 'window', 'late_join', 'system_audio']
    if not all(acceptance.get(key) == 'pass' for key in required):
        raise ValueError('Official Web picture and physical audio acceptance is incomplete')

def check(app, acceptance):
    build = json.loads((app.parent / 'build.json').read_text())
    validation = json.loads((app.parent / 'validation.json').read_text())
    validate_receipts(build, validation, tree(app), snapshot(), acceptance)
    return build, validation

def notarize(path, config, statefile, log, timeout=600):
    args = ['--key', str(file(config, 'notary_key')), '--key-id', config['notary_key_id'], '--issuer', config['notary_issuer']]
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    state = json.loads(statefile.read_text()) if statefile.exists() else {}
    if state.get('sha256') != digest:
        result = subprocess.run(['xcrun', 'notarytool', 'submit', str(path), *args, '--output-format', 'json'],
                                stdout=subprocess.PIPE, stderr=log, check=True)
        response = json.loads(result.stdout)
        if not response.get('id'): raise ValueError('No notarization submission ID; inspect private logs before retrying')
        state = {'id': response['id'], 'sha256': digest}; write(statefile, state)
    deadline = time.monotonic() + timeout
    while True:
        result = subprocess.run(['xcrun', 'notarytool', 'info', state['id'], *args, '--output-format', 'json'],
                                stdout=subprocess.PIPE, stderr=log, check=True)
        status = json.loads(result.stdout)['status']
        if status == 'Accepted': return
        if status in ('Invalid', 'Rejected'): raise ValueError('Notarization rejected; inspect submission privately')
        if time.monotonic() >= deadline: raise ValueError('Notarization pending; retry resumes the same unchanged submission')
        print('Notarization is pending', flush=True)
        time.sleep(15)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--acceptance', required=True, type=Path)
    args = parser.parse_args()
    version = plistlib.loads((ROOT / 'Info.plist').read_bytes())['CFBundleShortVersionString']
    app = ROOT / 'build' / version / 'Oopz.app'
    acceptance = json.loads(args.acceptance.read_text())
    build, validation = check(app, acceptance)
    config = load()
    if config.get('allow_public_certificate_identity') is not True:
        raise ValueError('Public Developer ID signatures disclose the certificate subject. Maintainer disclosure choice is unresolved.')
    for key, private in [('private_key', True), ('certificate_chain', False), ('notary_key', True)]: file(config, key, private)
    for key in ['notary_key_id', 'notary_issuer']:
        if not config.get(key): raise ValueError('Missing notarization configuration')
    if args.preflight:
        print('PASS: release preflight; no signing, upload or notarization performed'); return
    if (app.parent / 'release.json').exists(): raise ValueError('Release exists; do not overwrite a published version')
    # Preserve the exact tested app. Network timestamps modify only a separate distribution copy.
    staging = app.parent / '.distribution'
    staging.mkdir(exist_ok=True)
    dist = staging / 'Oopz.app'
    from fetch_signer import signer_path
    signer = signer_path(download=True)  # download before reading signing material
    with (app.parent / 'release.private.log').open('ab') as log:
        os.chmod(log.name, 0o600)
        signed_record = staging / 'signed.json'
        if not signed_record.exists():
            if dist.exists(): shutil.rmtree(dist)
            shutil.copytree(app, dist, symlinks=True)
            subprocess.run([str(signer), '--config-file', '/dev/null', 'sign', '--for-notarization',
                            '--pem-file', str(file(config, 'certificate_chain', False)), '--pem-file', str(file(config, 'private_key')),
                            '--entitlements-xml-file', str(ROOT / 'entitlements.plist'), str(dist)], stdout=log, stderr=log, check=True)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(dist)], stdout=log, stderr=log, check=True)
            write(signed_record, {'testedFiles': build['files'], 'files': tree(dist)})
        signed = json.loads(signed_record.read_text())
        if signed['testedFiles'] != build['files']: raise ValueError('Distribution copy belongs to a different validated build')
        if tree(dist) != signed['files']: raise ValueError('Distribution application changed since its last recorded signing/stapling step')
        archive = staging / 'application.zip'
        if not archive.exists():
            if tree(dist) != signed['files']: raise ValueError('Distribution application changed before submission')
            subprocess.run(['ditto', '-c', '-k', '--keepParent', str(dist), str(archive)], stdout=log, stderr=log, check=True)
            signed['archiveSHA256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
            write(signed_record, signed)
        if signed.get('archiveSHA256') != hashlib.sha256(archive.read_bytes()).hexdigest():
            raise ValueError('Notarization archive changed')
        notarize(archive, config, staging / 'app-notary.json', log)
        subprocess.run(['xcrun', 'stapler', 'staple', str(dist)], stdout=log, stderr=log, check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(dist)], stdout=log, stderr=log, check=True)
        subprocess.run(['spctl', '-a', '-t', 'exec', str(dist)], stdout=log, stderr=log, check=True)
        signed['files'] = tree(dist)
        write(signed_record, signed)
        dmg = app.parent / ('Oopz-' + version + '.dmg')
        if not dmg.exists():
            with tempfile.TemporaryDirectory(prefix='oopz-dmg-') as tmp:
                folder = Path(tmp)
                shutil.copytree(dist, folder / 'Oopz.app', symlinks=True)
                (folder / 'Applications').symlink_to('/Applications')
                subprocess.run(['hdiutil', 'create', '-volname', 'Oopz', '-srcfolder', str(folder), '-format', 'UDZO', str(dmg)], stdout=log, stderr=log, check=True)
            signed['dmgSHA256'] = hashlib.sha256(dmg.read_bytes()).hexdigest()
            write(signed_record, signed)
        if signed.get('dmgSHA256') != hashlib.sha256(dmg.read_bytes()).hexdigest():
            raise ValueError('Distribution DMG changed')
        notarize(dmg, config, staging / 'dmg-notary.json', log)
        subprocess.run(['xcrun', 'stapler', 'staple', str(dmg)], stdout=log, stderr=log, check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(dmg)], stdout=log, stderr=log, check=True)
    release = {'version': version, 'sourceCommit': build['source']['commit'], 'testedBinarySHA256': validation['sha256'],
               'artifact': dmg.name, 'sha256': hashlib.sha256(dmg.read_bytes()).hexdigest(), 'notarized': True}
    write(app.parent / 'release.json', release)
    (app.parent / 'SHA256SUMS').write_text(release['sha256'] + '  ' + dmg.name + '\n')
    print('PASS: notarized DMG prepared locally; publication is a separate explicit step')

if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError, FileNotFoundError, subprocess.CalledProcessError):
        # No traceback with credential-bearing paths or command arguments.
        raise SystemExit('Release stopped. Check receipts, acceptance, external signing configuration and private release logs.')
