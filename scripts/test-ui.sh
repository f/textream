#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

UI_LAYER="ui"
UI_SCHEME="${UI_TEST_SCHEME:-TextreamUI}"
UI_TIMEOUT_SECONDS="${UI_TEST_TIMEOUT_SECONDS:-240}"
UI_POLL_SECONDS="${UI_TEST_POLL_SECONDS:-5}"
UI_DIAGNOSTIC_SAMPLE_SECONDS="${UI_DIAGNOSTIC_SAMPLE_SECONDS:-3}"
UI_AUTOMATION_PREFLIGHT_TIMEOUT_SECONDS="${UI_AUTOMATION_PREFLIGHT_TIMEOUT_SECONDS:-8}"
TCC_DIAGNOSTIC_LOG_LOOKBACK="${TCC_DIAGNOSTIC_LOG_LOOKBACK:-10m}"
UI_CODE_SIGNING_ALLOWED="${UI_CODE_SIGNING_ALLOWED:-YES}"
UI_CODE_SIGNING_REQUIRED="${UI_CODE_SIGNING_REQUIRED:-NO}"
UI_CODE_SIGN_IDENTITY="${UI_CODE_SIGN_IDENTITY:--}"

if [[ -n "${CI:-}" ]]; then
  DEFAULT_UI_AUTOMATION_PREFLIGHT_REQUIRED=0
else
  DEFAULT_UI_AUTOMATION_PREFLIGHT_REQUIRED=1
fi

UI_AUTOMATION_PREFLIGHT_REQUIRED="${UI_AUTOMATION_PREFLIGHT_REQUIRED:-${DEFAULT_UI_AUTOMATION_PREFLIGHT_REQUIRED}}"

DERIVED_DATA_PATH="${BUILD_ROOT}/derived-data/${UI_LAYER}"
RESULT_BUNDLE_PATH="${BUILD_ROOT}/results/${UI_LAYER}.xcresult"
ARTIFACT_RESULT_BUNDLE_PATH="${ARTIFACT_ROOT}/results/${UI_LAYER}.xcresult"
LOG_PATH="${ARTIFACT_ROOT}/logs/${UI_LAYER}.log"
DIAGNOSTIC_PATH="${ARTIFACT_ROOT}/logs/${UI_LAYER}-diagnostics.log"
AUTOMATION_PREFLIGHT_LOG_PATH="${ARTIFACT_ROOT}/logs/${UI_LAYER}-automation-preflight.log"
UI_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug/Textream.app"
UI_RUNNER_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug/TextreamUITests-Runner.app"

cleanup_stale_ui_processes() {
  pkill -x Textream >/dev/null 2>&1 || true
  pkill -x TextreamUITests-Runner >/dev/null 2>&1 || true

  local stale_textream_pids
  stale_textream_pids="$(pgrep -f '/Textream.app/Contents/MacOS/Textream ' || true)"
  if [[ -n "${stale_textream_pids}" ]]; then
    while IFS= read -r pid; do
      [[ -z "${pid}" ]] && continue
      local parent_pid
      parent_pid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
      kill "${pid}" >/dev/null 2>&1 || true
      if [[ -n "${parent_pid}" && "${parent_pid}" != "1" ]]; then
        kill "${parent_pid}" >/dev/null 2>&1 || true
      fi
    done <<< "${stale_textream_pids}"
  fi

  sleep 1
  pkill -9 -x Textream >/dev/null 2>&1 || true
  pkill -9 -x TextreamUITests-Runner >/dev/null 2>&1 || true
  pkill -9 -f '/Textream.app/Contents/MacOS/Textream ' >/dev/null 2>&1 || true
}

resolve_active_xcodebuild_pid() {
  local wrapper_pid="$1"
  local child_pid
  child_pid="$(pgrep -P "${wrapper_pid}" xcodebuild | head -n 1 || true)"
  if [[ -n "${child_pid}" ]]; then
    printf '%s\n' "${child_pid}"
  else
    printf '%s\n' "${wrapper_pid}"
  fi
}

append_diagnostic() {
  local message="$1"
  printf '%s\n' "${message}" | tee -a "${DIAGNOSTIC_PATH}" >> "${LOG_PATH}"
}

run_ui_automation_preflight() {
  if [[ "${UI_TEST_SKIP_AUTOMATION_PREFLIGHT:-0}" == "1" ]]; then
    append_diagnostic "Skipping UI automation preflight because UI_TEST_SKIP_AUTOMATION_PREFLIGHT=1"
    return 0
  fi

  append_diagnostic "Running UI automation preflight through System Events"
  rm -f "${AUTOMATION_PREFLIGHT_LOG_PATH}"

  set +e
  /usr/bin/osascript >"${AUTOMATION_PREFLIGHT_LOG_PATH}" 2>&1 <<'APPLESCRIPT' &
tell application "System Events"
  count of application processes
end tell
APPLESCRIPT
  local preflight_pid=$!
  set -e

  local start_epoch
  start_epoch="$(date +%s)"

  while kill -0 "${preflight_pid}" >/dev/null 2>&1; do
    local now_epoch
    now_epoch="$(date +%s)"

    if (( now_epoch - start_epoch >= UI_AUTOMATION_PREFLIGHT_TIMEOUT_SECONDS )); then
      kill "${preflight_pid}" >/dev/null 2>&1 || true
      wait "${preflight_pid}" >/dev/null 2>&1 || true
      append_diagnostic "UI automation preflight timed out after ${UI_AUTOMATION_PREFLIGHT_TIMEOUT_SECONDS}s"
      append_diagnostic "This usually means macOS Automation/Accessibility approval has not completed for Terminal/Xcode/System Events."
      append_diagnostic "Open System Settings > Privacy & Security > Accessibility and Automation, then allow Terminal or Xcode to control your Mac and System Events."
      append_diagnostic "Quick links: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' and open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Automation'"
      return 1
    fi

    sleep 1
  done

  set +e
  wait "${preflight_pid}"
  local exit_code=$?
  set -e

  if (( exit_code != 0 )); then
    append_diagnostic "UI automation preflight failed with exit code ${exit_code}"
    if [[ -s "${AUTOMATION_PREFLIGHT_LOG_PATH}" ]]; then
      append_diagnostic "Preflight output: $(tr '\n' ' ' < "${AUTOMATION_PREFLIGHT_LOG_PATH}" | tr -s ' ')"
    fi
    return 1
  fi

  local output
  output="$(tr -d '\r\n' < "${AUTOMATION_PREFLIGHT_LOG_PATH}" || true)"
  append_diagnostic "UI automation preflight passed (System Events process count: ${output:-unknown})"
}

capture_ui_diagnostics() {
  local runner_pid="${1:-}"
  local xcodebuild_pid="${2:-}"

  append_diagnostic ""
  append_diagnostic "===== UI diagnostics @ $(date '+%Y-%m-%d %H:%M:%S') ====="
  append_diagnostic "ui_scheme=${UI_SCHEME}"
  append_diagnostic "derived_data_path=${DERIVED_DATA_PATH}"
  append_diagnostic "result_bundle_path=${RESULT_BUNDLE_PATH}"

  {
    echo "----- process snapshot -----"
    ps -Ao pid,ppid,etime,stat,command | rg 'xcodebuild|TextreamUITests-Runner|/Textream.app/Contents/MacOS/Textream |debugserver|testmanagerd' || true
    echo
    echo "----- xctestrun + xctestconfiguration -----"
    find "${DERIVED_DATA_PATH}" -name '*.xctestrun' -o -name '*.xctestconfiguration' | sort || true
    echo
    echo "----- runner environment -----"
    if [[ -n "${runner_pid}" ]] && ps -p "${runner_pid}" >/dev/null 2>&1; then
      ps eww -p "${runner_pid}" || true
    else
      echo "runner pid unavailable"
    fi
    echo
    echo "----- codesign validation -----"
    codesign -vvv --strict "${UI_APP_PATH}" || true
    codesign -vvv --strict "${UI_RUNNER_PATH}" || true
    echo
    echo "----- automation preflight -----"
    if [[ -f "${AUTOMATION_PREFLIGHT_LOG_PATH}" ]]; then
      cat "${AUTOMATION_PREFLIGHT_LOG_PATH}" || true
    else
      echo "automation preflight log unavailable"
    fi
    echo
    echo "----- TCC / XCTest logs -----"
    /usr/bin/log show --last "${TCC_DIAGNOSTIC_LOG_LOOKBACK}" --style compact --predicate 'process == "tccd" OR process == "testmanagerd" OR process == "xcodebuild" OR process == "TextreamUITests-Runner" OR eventMessage CONTAINS[c] "XCTest" OR eventMessage CONTAINS[c] "TCCAccessRequest" OR eventMessage CONTAINS[c] "System Events" OR eventMessage CONTAINS[c] "kTCCServiceAccessibility"' | tail -n 120 || true
    echo
    echo "----- recent DiagnosticReports -----"
    find "${HOME}/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \( -name 'TextreamUITests-Runner*' -o -name 'XCTRunner*' -o -name 'xctest*' \) -mmin -20 -print | sort || true
  } >> "${DIAGNOSTIC_PATH}"

  if [[ -n "${runner_pid}" ]] && ps -p "${runner_pid}" >/dev/null 2>&1; then
    append_diagnostic "sampling runner pid ${runner_pid} for ${UI_DIAGNOSTIC_SAMPLE_SECONDS}s"
    sample "${runner_pid}" "${UI_DIAGNOSTIC_SAMPLE_SECONDS}" -mayDie >> "${DIAGNOSTIC_PATH}" 2>&1 || true
  fi

  if [[ -n "${xcodebuild_pid}" ]] && ps -p "${xcodebuild_pid}" >/dev/null 2>&1; then
    append_diagnostic "sampling xcodebuild pid ${xcodebuild_pid} for ${UI_DIAGNOSTIC_SAMPLE_SECONDS}s"
    sample "${xcodebuild_pid}" "${UI_DIAGNOSTIC_SAMPLE_SECONDS}" -mayDie >> "${DIAGNOSTIC_PATH}" 2>&1 || true
  fi
}

start_runner_monitor() {
  local wrapper_pid="$1"

  (
    local seen_runner_pid=""

    while kill -0 "${wrapper_pid}" >/dev/null 2>&1; do
      local runner_pid
      runner_pid="$(pgrep -x TextreamUITests-Runner | head -n 1 || true)"

      if [[ -n "${runner_pid}" && "${runner_pid}" != "${seen_runner_pid}" ]]; then
        append_diagnostic "observed TextreamUITests-Runner pid ${runner_pid}"
        ps eww -p "${runner_pid}" >> "${DIAGNOSTIC_PATH}" 2>&1 || true
        sample "${runner_pid}" 1 -mayDie >> "${DIAGNOSTIC_PATH}" 2>&1 || true
        seen_runner_pid="${runner_pid}"
      fi

      sleep 1
    done
  ) &

  printf '%s\n' "$!"
}

validate_ui_codesign() {
  local validation_failed=0

  if [[ ! -d "${UI_APP_PATH}" ]]; then
    append_diagnostic "UI app bundle missing at ${UI_APP_PATH}"
    validation_failed=1
  elif ! codesign -vvv --strict "${UI_APP_PATH}" >> "${DIAGNOSTIC_PATH}" 2>&1; then
    append_diagnostic "UI app bundle failed codesign validation at ${UI_APP_PATH}"
    validation_failed=1
  fi

  if [[ ! -d "${UI_RUNNER_PATH}" ]]; then
    append_diagnostic "UI runner bundle missing at ${UI_RUNNER_PATH}"
    validation_failed=1
  elif ! codesign -vvv --strict "${UI_RUNNER_PATH}" >> "${DIAGNOSTIC_PATH}" 2>&1; then
    append_diagnostic "UI runner bundle failed codesign validation at ${UI_RUNNER_PATH}"
    validation_failed=1
  fi

  return "${validation_failed}"
}

mkdir -p "${BUILD_ROOT}/derived-data" "${BUILD_ROOT}/results" "${ARTIFACT_ROOT}/results" "${ARTIFACT_ROOT}/logs"
rm -rf "${DERIVED_DATA_PATH}" "${RESULT_BUNDLE_PATH}" "${ARTIFACT_RESULT_BUNDLE_PATH}"
rm -f "${LOG_PATH}" "${DIAGNOSTIC_PATH}" "${AUTOMATION_PREFLIGHT_LOG_PATH}"

# macOS UI tests can stall if a manually launched Textream instance is already
# running under the same bundle identifier. Clear any stale app/runner first so
# XCUIApplication().launch() always gets a fresh AUT session.
cleanup_stale_ui_processes

if ! run_ui_automation_preflight; then
  if [[ "${UI_AUTOMATION_PREFLIGHT_REQUIRED}" == "1" ]]; then
    append_diagnostic "Aborting UI tests before build because the UI automation preflight did not complete."
    exit 125
  fi

  append_diagnostic "UI automation preflight failed, but continuing because UI_AUTOMATION_PREFLIGHT_REQUIRED=${UI_AUTOMATION_PREFLIGHT_REQUIRED}"
fi

build_cmd=(
  xcodebuild
  -project "${PROJECT_PATH}"
  -scheme "${UI_SCHEME}"
  -configuration "${CONFIGURATION}"
  -sdk "${SDK}"
  "CODE_SIGNING_ALLOWED=${UI_CODE_SIGNING_ALLOWED}"
  "CODE_SIGNING_REQUIRED=${UI_CODE_SIGNING_REQUIRED}"
  "CODE_SIGN_IDENTITY=${UI_CODE_SIGN_IDENTITY}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  build-for-testing
)

{
  printf '== UI build-for-testing ==\n'
  (
    cd "${REPO_ROOT}"
    "${build_cmd[@]}"
  )
} | tee "${LOG_PATH}"

append_diagnostic "Validating UI build products with codesign --strict"
if ! validate_ui_codesign; then
  append_diagnostic "UI build products are not launchable for XCTest. UI tests require a valid locally signed runner bundle."
  append_diagnostic "Current settings: CODE_SIGNING_ALLOWED=${UI_CODE_SIGNING_ALLOWED} CODE_SIGNING_REQUIRED=${UI_CODE_SIGNING_REQUIRED} CODE_SIGN_IDENTITY=${UI_CODE_SIGN_IDENTITY}"
  exit 1
fi

XCTESTRUN_PATH="$(find "${DERIVED_DATA_PATH}/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -n 1)"
if [[ -z "${XCTESTRUN_PATH}" ]]; then
  append_diagnostic "Failed to locate .xctestrun under ${DERIVED_DATA_PATH}/Build/Products"
  exit 1
fi

test_cmd=(
  xcodebuild
  test-without-building
  -xctestrun "${XCTESTRUN_PATH}"
  -only-testing:TextreamUITests
  -destination "platform=macOS,arch=arm64"
  -resultBundlePath "${RESULT_BUNDLE_PATH}"
)

{
  printf '\n== UI test-without-building ==\n'
} | tee -a "${LOG_PATH}"

set +e
(
  cd "${REPO_ROOT}"
  "${test_cmd[@]}"
) >> "${LOG_PATH}" 2>&1 &
test_wrapper_pid=$!
runner_monitor_pid="$(start_runner_monitor "${test_wrapper_pid}")"
set -e

start_epoch="$(date +%s)"
diagnostics_captured=0

while kill -0 "${test_wrapper_pid}" >/dev/null 2>&1; do
  now_epoch="$(date +%s)"
  elapsed="$((now_epoch - start_epoch))"
  active_xcodebuild_pid="$(resolve_active_xcodebuild_pid "${test_wrapper_pid}")"

  if (( diagnostics_captured == 0 )) && (( elapsed >= 45 )); then
    runner_pid="$(pgrep -x TextreamUITests-Runner | head -n 1 || true)"
    capture_ui_diagnostics "${runner_pid}" "${active_xcodebuild_pid}"
    diagnostics_captured=1
  fi

  if (( elapsed >= UI_TIMEOUT_SECONDS )); then
    runner_pid="$(pgrep -x TextreamUITests-Runner | head -n 1 || true)"
    append_diagnostic "UI tests exceeded timeout (${UI_TIMEOUT_SECONDS}s)"
    capture_ui_diagnostics "${runner_pid}" "${active_xcodebuild_pid}"
    kill "${active_xcodebuild_pid}" >/dev/null 2>&1 || true
    kill "${test_wrapper_pid}" >/dev/null 2>&1 || true
    if [[ -n "${runner_pid}" ]]; then
      kill "${runner_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${runner_monitor_pid}" ]]; then
      kill "${runner_monitor_pid}" >/dev/null 2>&1 || true
      wait "${runner_monitor_pid}" >/dev/null 2>&1 || true
    fi
    cleanup_stale_ui_processes
    wait "${test_wrapper_pid}" >/dev/null 2>&1 || true
    exit 124
  fi

  sleep "${UI_POLL_SECONDS}"
done

set +e
wait "${test_wrapper_pid}"
exit_code=$?
set -e

if [[ -n "${runner_monitor_pid}" ]]; then
  kill "${runner_monitor_pid}" >/dev/null 2>&1 || true
  wait "${runner_monitor_pid}" >/dev/null 2>&1 || true
fi

if [[ -d "${RESULT_BUNDLE_PATH}" ]]; then
  cp -R "${RESULT_BUNDLE_PATH}" "${ARTIFACT_RESULT_BUNDLE_PATH}"
fi

if (( exit_code != 0 )); then
  runner_pid="$(pgrep -x TextreamUITests-Runner | head -n 1 || true)"
  active_xcodebuild_pid="$(resolve_active_xcodebuild_pid "${test_wrapper_pid}")"
  append_diagnostic "UI tests exited with code ${exit_code}"
  capture_ui_diagnostics "${runner_pid}" "${active_xcodebuild_pid}"
fi

exit "${exit_code}"
