#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/textream-audio-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT" "$TEST_DIR" <<'PY'
from pathlib import Path
import platform, subprocess, sys
root, temp = map(Path, sys.argv[1:])
sources = sorted((root / 'Textream/Textream').glob('*.swift'))
entry = root / 'Textream/Textream/TextreamApp.swift'
# Compile the production types with a test entry point instead of launching UI.
(temp / 'TextreamApp.swift').write_text(entry.read_text().replace('@main\n', ''))
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target',
                platform.machine() + '-apple-macos15.0', '-module-cache-path',
                str(root / 'Textream/build/TestModuleCache'),
                *map(str, (p for p in sources if p != entry)),
                str(temp / 'TextreamApp.swift'), str(root / 'Tests/AudioCleanup/main.swift'),
                '-o', str(temp / 'audio-cleanup-test')], check=True)
try:
    subprocess.run([str(temp / 'audio-cleanup-test')], check=True, timeout=10)
except subprocess.TimeoutExpired:
    print('FAIL: stopping an unused recognizer blocked for 10 seconds', flush=True)
    sys.exit(1)
PY
