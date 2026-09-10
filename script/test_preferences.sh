#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$ROOT_DIR/.build/preferences-tests"
mkdir -p "$TEST_DIR"
swiftc -swift-version 5 \
  "$ROOT_DIR/Textream/Textream/NotchSettings.swift" \
  "$ROOT_DIR/Textream/Textream/LanguageDetection.swift" \
  "$ROOT_DIR/Textream/Textream/SpeechTextAlignment.swift" \
  "$ROOT_DIR/Textream/Textream/FloatingWindowGeometry.swift" \
  "$ROOT_DIR/Textream/Textream/PrompterLineGeometry.swift" \
  "$ROOT_DIR/Tests/PrompterPreferencesTests.swift" \
  -o "$TEST_DIR/preferences-tests"
"$TEST_DIR/preferences-tests"
swiftc -swift-version 5 \
  "$ROOT_DIR/Textream/Textream/SpeechTextAlignment.swift" \
  "$ROOT_DIR/Textream/Textream/SpeechRecoveryMatcher.swift" \
  "$ROOT_DIR/Textream/Textream/SpeechRecognizer.swift" \
  "$ROOT_DIR/Textream/Textream/VoiceActivityDetector.swift" \
  "$ROOT_DIR/Tests/SpeechRecoveryTests.swift" \
  -o "$TEST_DIR/speech-recovery-tests"
"$TEST_DIR/speech-recovery-tests"
