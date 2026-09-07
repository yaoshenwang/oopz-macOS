#!/usr/bin/env python3
"""Publish an audited clean source commit to an explicitly chosen GitHub repository.

Default is a read-only local preflight. --publish is an external action.
GitHub authentication uses the existing local gh login or process environment.
Build and test processes never receive these credentials.
"""
import argparse
import json
import os
import re
import subprocess
import time
from audit_public import ROOT
from manifest import snapshot

def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('repository', help='Explicit OWNER/REPOSITORY; its owner will be public')
    p.add_argument('--publish', action='store_true')
    args = p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', args.repository):
        raise SystemExit('Expected OWNER/REPOSITORY')
    run(['python3', 'tools/audit_public.py', '--history'])
    source = snapshot()
    if not source['commit'] or source['dirty']: raise SystemExit('Commit reviewed source and keep the checkout clean first')
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    if branch != 'main': raise SystemExit('Initial publication must use the reviewed main branch')
    if not args.publish:
        print('PASS: local source publication preflight; nothing uploaded'); return
    login = subprocess.check_output(['gh', 'api', 'user', '--jq', '.login'], cwd=ROOT, text=True).strip()
    if login.lower() != args.repository.split('/')[0].lower():
        raise SystemExit('Authenticated GitHub account differs from the requested repository owner')
    remote = 'https://github.com/' + args.repository + '.git'
    existing = subprocess.run(['git', 'remote', 'get-url', 'origin'], cwd=ROOT, capture_output=True, text=True)
    if existing.returncode == 0 and existing.stdout.strip() != remote:
        raise SystemExit('Existing origin differs from requested destination')
    # Repository creation is explicit; a conflicting existing repository is not overwritten.
    if existing.returncode != 0:
        run(['gh', 'repo', 'create', args.repository, '--public', '--description', 'Native macOS community client for OOPZ'])
        run(['git', 'remote', 'add', 'origin', remote])
    run(['git', '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential', 'push', '-u', 'origin', 'main'])
    run_id = None
    for _ in range(12):
        result = subprocess.check_output(['gh', 'run', 'list', '--repo', args.repository, '--workflow', 'ci.yml',
                                          '--commit', source['commit'], '--json', 'databaseId', '--limit', '1'], cwd=ROOT)
        rows = json.loads(result)
        if rows: run_id = str(rows[0]['databaseId']); break
        time.sleep(5)
    if not run_id: raise SystemExit('Source uploaded, but CI run has not appeared. Inspect Actions before retrying publication.')
    run(['gh', 'run', 'watch', run_id, '--repo', args.repository, '--exit-status'])
    protection = {
        'required_status_checks': {'strict': True, 'contexts': ['Check']},
        'enforce_admins': True,
        'required_pull_request_reviews': {'required_approving_review_count': 0, 'dismiss_stale_reviews': True},
        'restrictions': None, 'allow_force_pushes': False, 'allow_deletions': False,
        'required_conversation_resolution': True,
    }
    run(['gh', 'api', '--method', 'PUT', 'repos/' + args.repository + '/branches/main/protection', '--input', '-'],
        input=json.dumps(protection).encode(), stdout=subprocess.DEVNULL)
    run(['gh', 'repo', 'edit', args.repository, '--delete-branch-on-merge', '--enable-issues', '--enable-wiki=false'])
    run(['gh', 'api', '--method', 'PUT', 'repos/' + args.repository + '/private-vulnerability-reporting'], stdout=subprocess.DEVNULL)
    print('PASS: source published, hosted CI passed, branch protection and private reporting configured')

if __name__ == '__main__': main()
