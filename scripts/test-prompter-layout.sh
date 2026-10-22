#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/textream-layout-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Keep the tests in the same file so they can inspect the private layout cache
# without widening the app's access control or modifying its Xcode targets.
cat "$ROOT/Textream/Textream/MarqueeTextView.swift" \
    "$ROOT/tests/PrompterLayoutTests.swift" > "$TEST_DIR/LayoutTests.swift"
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "$TEST_DIR/ModuleCache" \
    "$ROOT/Textream/Textream/SpeechTextAlignment.swift" \
    "$ROOT/Textream/Textream/TextDirection.swift" \
    "$TEST_DIR/LayoutTests.swift" -o "$TEST_DIR/layout-tests"
"$TEST_DIR/layout-tests" "$ROOT"
