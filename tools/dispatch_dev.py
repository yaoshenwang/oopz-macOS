#!/usr/bin/env python3
"""Dispatch from trusted main; Apple credentials remain in the tag-only workflow."""
import json
import os
from pathlib import Path
import plistlib
import subprocess

from build_channel import dev_tag


def api(endpoint, payload=None):
    args = ['gh', 'api', endpoint]
    if payload is not None:
        args += ['--method', 'POST', '--input', '-']
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def main():
    if os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('Dev dispatch requires main')
    commit = os.environ['GITHUB_SHA']
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() != commit:
        raise ValueError('Checkout does not match the requested commit')
    subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'origin/main'], check=True)
    version = plistlib.loads(Path('Info.plist').read_bytes())['CFBundleShortVersionString']
    tag = dev_tag(version, commit, os.environ['GITHUB_RUN_ID'], os.environ['GITHUB_RUN_ATTEMPT'])
    repository = os.environ['GITHUB_REPOSITORY']
    # Each rerun gets a new attempt suffix. Never move or overwrite a tag.
    api(f'repos/{repository}/git/refs', {'ref': 'refs/tags/' + tag, 'sha': commit})
    # GITHUB_TOKEN-created tag pushes do not trigger workflows; explicit dispatch does.
    api(f'repos/{repository}/actions/workflows/release.yml/dispatches', {'ref': tag})
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f'### Dev build requested: `{tag}`\n\n'
                      f'[Installer runs](https://github.com/{repository}/actions/workflows/release.yml) '
                      'contain the signed DMG / ZIP after all checks pass. '
                      'Dispatch success alone does not mean the installer succeeded.\n')
    print('PASS: dev tag created and installer workflow dispatched: ' + tag)


if __name__ == '__main__':
    main()
