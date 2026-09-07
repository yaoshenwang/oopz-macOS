#!/usr/bin/env python3
"""Bounded native checks and a manifest tied to the exact executable tested."""
import hashlib, json, os, subprocess, sys, time
from pathlib import Path
from manifest import tree, snapshot, write

binary = Path(sys.argv[1]).resolve()
media = sys.argv[2] == '1'
out = Path(os.environ['OOPZ_TEST_RESULTS'])
app = binary.parents[2]
record = json.loads((app.parent / 'build.json').read_text())
if record['signing'] != 'local-developer-id' or tree(app) != record['files']:
    raise SystemExit('App differs from its signed build record')
if record['source'] != snapshot():
    raise SystemExit('Source differs from the build record')
app_before = tree(app)
child_env = {k: v for k, v in os.environ.items() if k in ('HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'OOPZ_DATA_DIR', 'OOPZ_TEST_RESULTS')}
started = time.monotonic()
digest = lambda: hashlib.sha256(binary.read_bytes()).hexdigest()
before = digest()
steps = []
for mode, result_file in [('--smoke', 'protocol.json')] + ([('--media-test', 'publisher.json')] if media else []):
    clock = time.monotonic()
    with (out / (mode[2:] + '.log')).open('w') as log:
        process = subprocess.Popen([str(binary), mode], stdout=log, stderr=subprocess.STDOUT, env=child_env)
        try:
            rc = process.wait(timeout=150)
        except subprocess.TimeoutExpired:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            rc = 124
    payload = json.loads((out / result_file).read_text()) if (out / result_file).exists() else {}
    passed = rc == 0 and payload.get('pass') is True
    steps.append({'mode': mode, 'pass': passed, 'exitCode': rc, 'durationSeconds': round(time.monotonic()-clock, 2)})
    for line in (out / (mode[2:]+'.log')).read_text().splitlines():
        if any(marker in line for marker in ('✅', '❌', '====')): print(line)
    if not passed: break
passed = all(step['pass'] for step in steps) and digest() == before and tree(app) == app_before
result = {'pass': passed, 'scope': 'local-checks', 'binary': 'Oopz.app/Contents/MacOS/Oopz', 'sha256': before,
          'durationSeconds': round(time.monotonic()-started, 2), 'steps': steps,
          'officialWeb': 'pending-manual', 'physicalCapture': 'pending-manual', 'sourceCommit': record['source']['commit'], 'files': app_before}
(out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
write(app.parent / 'validation.json', result)
print('PASS' if passed else 'FAIL', 'local validation receipt saved beside application')
raise SystemExit(0 if passed else 3)
