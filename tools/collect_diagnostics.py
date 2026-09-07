#!/usr/bin/env python3
"""Export only this release's structured, private-interpolation application logs.

Old free-form diagnostic files are never copied. Review the resulting local file before sharing.
"""
import json
import os
from pathlib import Path
import tempfile

source = Path.home() / 'Library/Logs/Oopz'
out = Path(tempfile.mkdtemp(prefix='oopz-diagnostics-'))
count = 0
with (out / 'diagnostics.txt').open('w') as target:
    os.chmod(target.name, 0o600)
    for file in sorted(source.glob('diagnostic-*.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True)[:2]:
        for line in file.read_text().splitlines():
            try: record = json.loads(line)
            except ValueError: continue
            if record.get('schema') != 'private-interpolation-v1': continue
            safe = {key: record[key] for key in ['version', 'message'] if key in record}
            target.write(json.dumps(safe, ensure_ascii=False) + '\n'); count += 1
print(f'Exported {count} structured diagnostic events to a private temporary directory.')
print(out)
