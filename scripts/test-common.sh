#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/Textream/Textream.xcodeproj"
SCHEME="Textream"
CONFIGURATION="${CONFIGURATION:-Debug}"
SDK="${SDK:-macosx}"
BUILD_ROOT="${TEST_BUILD_ROOT:-${TMPDIR%/}/textream-tests}"
ARTIFACT_ROOT="${REPO_ROOT}/.build/tests"

run_test_layer() {
  local layer="$1"
  local only_testing_target="$2"
  shift 2

  local derived_data_path="${BUILD_ROOT}/derived-data/${layer}"
  local result_bundle_path="${BUILD_ROOT}/results/${layer}.xcresult"
  local artifact_result_bundle_path="${ARTIFACT_ROOT}/results/${layer}.xcresult"
  local log_path="${ARTIFACT_ROOT}/logs/${layer}.log"

  mkdir -p "${BUILD_ROOT}/derived-data" "${BUILD_ROOT}/results" "${ARTIFACT_ROOT}/results" "${ARTIFACT_ROOT}/logs"
  rm -rf "${derived_data_path}" "${result_bundle_path}" "${artifact_result_bundle_path}"

  local -a cmd=(
    xcodebuild
    -project "${PROJECT_PATH}"
    -scheme "${SCHEME}"
    -configuration "${CONFIGURATION}"
    -sdk "${SDK}"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    -derivedDataPath "${derived_data_path}"
    -resultBundlePath "${result_bundle_path}"
    -parallel-testing-enabled NO
    test
    "-only-testing:${only_testing_target}"
  )

  if [[ "$#" -gt 0 ]]; then
    cmd+=("$@")
  fi

  set +e
  (
    cd "${REPO_ROOT}"
    "${cmd[@]}"
  ) | tee "${log_path}"
  local exit_code=${PIPESTATUS[0]}
  set -e

  if [[ -d "${result_bundle_path}" ]]; then
    cp -R "${result_bundle_path}" "${artifact_result_bundle_path}"
  fi

  return "${exit_code}"
}
