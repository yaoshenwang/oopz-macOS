#!/usr/bin/env python3
"""Check the supported test entry points, independent of maintainer signing configuration."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
errors = []
for path in (root / 'Sources').rglob('*.swift'):
    text = path.read_text()
    if re.search(r'\b(SecItemCopyMatching|SecItemAdd|SecItemUpdate|SecKeychain\w+)\s*\(', text):
        errors.append(path.name + ': Keychain API')
headless = (root / 'Sources/Oopz/Core/SmokeTest.swift').read_text()
for forbidden in ['CGMainDisplayID', 'startScreenShare', 'runIMProbe', 'runPasswordLogin', 'DuoTest.run']:
    if forbidden in headless: errors.append('Unsafe headless command: ' + forbidden)
verify = (root / 'Sources/Oopz/Core/Verification.swift').read_text()
for required in ['$0.owner == app.api.session?.uid', 'members[channel.id]?.isEmpty == true', 'AccountLock.acquire']:
    if required not in verify: errors.append('Missing account/room isolation')
media = (root / 'Sources/Oopz/Core/MediaSynth.swift').read_text()
attach = media.split('func attach(', 1)[1].split('func setAudio', 1)[0]
if 'self.audioTrackId = -1' not in attach or 'self.audioTrackId = audioTrackId' in attach:
    errors.append('Synthetic audio must remain disconnected')
agora = (root / 'Sources/Oopz/Core/AgoraManager.swift').read_text()
if 'disableAudio()' not in agora: errors.append('Missing headless audio shutdown')
app = (root / 'Sources/Oopz/Core/AppModel.swift').read_text()
if 'func log(_ m: DiagnosticMessage)' not in app: errors.append('Unstructured diagnostic input')
for workflow in (root / '.github/workflows').glob('*.yml'):
    text = workflow.read_text()
    if any(x in text for x in ['pull_request_target:', 'secrets.', 'self-hosted']): errors.append('Privileged public CI')
    for line in text.splitlines():
        if 'uses:' in line and not re.search(r'@[a-f0-9]{40}\b', line): errors.append('Unpinned action')
if errors: raise SystemExit('\n'.join('FAIL: ' + x for x in errors))
print('PASS: account, room, audio, diagnostic and CI isolation')
