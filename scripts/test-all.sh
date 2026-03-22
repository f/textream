#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/test-unit.sh"
"${SCRIPT_DIR}/test-integration.sh"
"${SCRIPT_DIR}/test-ui.sh"
