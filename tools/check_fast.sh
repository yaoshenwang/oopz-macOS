#!/bin/bash
# Offline edit loop: no app, RTC, network, devices or signing credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/check_test_safety.py
python3 tools/check_resources.py
TASK_DIR=$(mktemp -d /tmp/oopz-fast.XXXXXX)
trap 'rm -rf "$TASK_DIR"' EXIT
python3 - "$TASK_DIR/pcm.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(Path('Sources/Oopz/Core/PCMConverter.swift').read_text() + '\nprecondition(PCMConverter.selfTest(), "PCM conversion failed")\nprint("PASS: PCM interleaved / planar / mono values")\n')
PY
swift "$TASK_DIR/pcm.swift"

python3 - "$TASK_DIR/permissions.swift" <<'PYTEST'
from pathlib import Path
import sys
source = 'enum RunMode { static var headless = true }\n'
for name in ('PermissionCenter', 'PermissionChecks'):
    source += Path(f'Sources/Oopz/Core/{name}.swift').read_text() + '\n'
source += '\nTask { @MainActor in\n    let checks = await PermissionChecks.run()\n    for (name, passed) in checks { print("\\(passed ? "PASS" : "FAIL"): \\(name)") }\n    exit(checks.allSatisfy { $0.1 } ? 0 : 1)\n}\nRunLoop.main.run()\n'
Path(sys.argv[1]).write_text(source)
PYTEST
swift "$TASK_DIR/permissions.swift"

python3 - "$TASK_DIR/privacy.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Sources/Oopz/Core/DiagnosticMessage.swift').read_text() + '\n' + Path('Tests/DiagnosticMessageChecks.swift').read_text()
Path(sys.argv[1]).write_text(source)
PYTEST
swift "$TASK_DIR/privacy.swift"
python3 - "$TASK_DIR/protocol.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Sources/Oopz/Core/OopzSign.swift').read_text() + '\n' + Path('Tests/ProtocolChecks.swift').read_text()
Path(sys.argv[1]).write_text(source)
PYTEST
swift "$TASK_DIR/protocol.swift"
python3 - "$TASK_DIR/storage.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Sources/Oopz/Core/SessionStore.swift').read_text() + '\n' + Path('Tests/SessionStoreChecks.swift').read_text()
Path(sys.argv[1]).write_text(source)
PYTEST
OOPZ_DATA_DIR="$TASK_DIR/storage" swift "$TASK_DIR/storage.swift"
python3 - "$TASK_DIR/web-login.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Sources/Oopz/Core/WebLoginBridge.swift').read_text() + '\n' + Path('Tests/WebLoginBridgeChecks.swift').read_text()
Path(sys.argv[1]).write_text(source)
PYTEST
swift "$TASK_DIR/web-login.swift"
python3 -m unittest discover -s Tests -p 'test_*.py'
