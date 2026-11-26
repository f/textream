#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/textream-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc \
  -module-cache-path "$ROOT/Textream/build/TestModuleCache" \
  "$ROOT/Textream/Textream/PromptNavigation.swift" \
  "$ROOT/Textream/Textream/PrompterKeyboardShortcuts.swift" \
  "$ROOT/Tests/main.swift" \
  -o "$TEST_DIR/navigation-tests"
"$TEST_DIR/navigation-tests"
