"""Strict channel identities shared by dispatch, packaging and distribution checks."""
import re


def channel(tag, version, commit=None):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid Info.plist version')
    if tag == 'v' + version:
        return 'stable'
    match = re.fullmatch(re.escape('v' + version) + r'-dev\.([1-9][0-9]*)\.([1-9][0-9]*)\.g([a-f0-9]{12})', tag)
    if not match or (commit is not None and match[3] != commit[:12]):
        raise ValueError('Tag must match the source version and dev commit')
    return 'dev'


def dev_tag(version, commit, run_id, attempt):
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('Invalid source commit')
    tag = f'v{version}-dev.{run_id}.{attempt}.g{commit[:12]}'
    channel(tag, version, commit)
    return tag
