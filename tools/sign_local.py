#!/usr/bin/env python3
"""Explicit Developer ID file signing, isolated from networking and Keychains."""
import os
from pathlib import Path
import subprocess
import sys
from fetch_signer import signer_path
from local_config import load, file, ROOT

PROFILE = '''(version 1)
(allow default)
(deny network*)
(deny mach-lookup (global-name "com.apple.securityd"))
(deny file-read* (regex #"/Library/Keychains(/|$)"))
'''

def sign(app, config):
    key, cert = file(config, 'private_key'), file(config, 'certificate_chain', private=False)
    team = config.get('team_id', '')
    if len(team) != 10 or not team.isalnum(): raise SystemExit('Invalid team_id')
    subprocess.run(['/usr/bin/openssl', 'x509', '-in', str(cert), '-checkend', '0', '-noout'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(Path.home()), 'TMPDIR': os.environ.get('TMPDIR', '/tmp')}
    command = ['/usr/bin/sandbox-exec', '-p', PROFILE, str(signer_path(False)), '--config-file', '/dev/null', 'sign',
               '--pem-file', str(cert), '--pem-file', str(key), '--timestamp-url', 'none',
               '--code-signature-flags', 'runtime', '--entitlements-xml-file', str(ROOT / 'entitlements.plist'), str(app)]
    # Signer/codesign diagnostics may contain a person's certificate name; keep them private.
    with (app.parent / 'signing.private.log').open('wb') as log:
        os.chmod(log.name, 0o600)
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        requirement = ('identifier "cn.oopz.mac" and anchor apple generic and '
                       'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
                       'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                       f'certificate leaf[subject.OU] = "{team}"')
        for arch in ('arm64', 'x86_64'):
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--arch', arch,
                            '-R', '=' + requirement, str(app)], stdout=log, stderr=subprocess.STDOUT, check=True)
    print('PASS: local Developer ID signature; certificate identity remains in this private artifact')

if __name__ == '__main__':
    try: sign(Path(sys.argv[1]).resolve(), load())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise SystemExit('Local signing failed; inspect the private signing log. No fallback identity was used.')
