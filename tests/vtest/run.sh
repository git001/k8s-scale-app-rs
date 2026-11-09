#!/usr/bin/env bash
# Run the VTest2 tests of k8s-scale-app-rs, optionally with combined coverage.
#
# Usage (from anywhere in the repository):
#   tests/vtest/run.sh                     # VTest2 tests only
#   tests/vtest/run.sh --coverage          # unit + Rust integration + VTest2,
#                                          # combined text report
#   tests/vtest/run.sh --coverage --html   # the same as an HTML report
#   tests/vtest/run.sh -v                  # verbose vtest output
#   tests/vtest/run.sh tests/vtest/v0001_scale.vtc   # a single test
#
# Environment variables:
#   VTEST         Path to the vtest binary (default: /datadisk/git-repos/VTest2/vtest)
#   K8S_SCALE_BIN Path to the binary       (default: target/debug/k8s-scale-app-rs)
#                 Ignored in --coverage mode, which builds its own.
#   CLUSTER_TEST  Set to 1 to run tests/cluster.rs against the cluster in
#                 KUBECONFIG in --coverage mode. Otherwise KUBECONFIG is unset,
#                 so that a coverage run never contacts the current cluster.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VTEST="${VTEST:-/datadisk/git-repos/VTest2/vtest}"

COVERAGE=false
HTML=false
VTC_FILES=()
VTEST_OPTS=()

for arg in "$@"; do
    case "${arg}" in
        --coverage) COVERAGE=true ;;
        --html)     HTML=true ;;
        *.vtc)      VTC_FILES+=("${arg}") ;;
        *)          VTEST_OPTS+=("${arg}") ;;
    esac
done

if [[ ${#VTC_FILES[@]} -eq 0 ]]; then
    VTC_FILES=("${REPO_ROOT}/tests/vtest/"v*.vtc)
fi

if [[ ! -x "${VTEST}" ]]; then
    echo "ERROR: vtest not found at ${VTEST}; set VTEST=/path/to/vtest" >&2
    exit 1
fi

cd "${REPO_ROOT}"

# All tests listen on the fixed port of fixtures/kubeconfig.yaml, so they must
# not run in parallel: -j 1.
run_vtest() {
    "${VTEST}" -j 1 \
        -Dk8s_scale="$1" \
        -Dvtestdir="${REPO_ROOT}/tests/vtest" \
        "${VTEST_OPTS[@]}" \
        "${VTC_FILES[@]}"
}

if [[ "${COVERAGE}" == false ]]; then
    K8S_SCALE_BIN="${K8S_SCALE_BIN:-${REPO_ROOT}/target/debug/k8s-scale-app-rs}"
    if [[ ! -x "${K8S_SCALE_BIN}" ]]; then
        echo "ERROR: binary not found at ${K8S_SCALE_BIN}; run: cargo build" >&2
        exit 1
    fi
    run_vtest "${K8S_SCALE_BIN}"
    exit
fi

if ! cargo llvm-cov --version &>/dev/null; then
    echo "ERROR: cargo-llvm-cov is missing; run: cargo install cargo-llvm-cov --locked" >&2
    exit 1
fi

if [[ "${CLUSTER_TEST:-0}" != 1 ]]; then
    unset KUBECONFIG
fi

echo "==> Loading the coverage environment"
# Instrumented builds get their own target directory, so target/debug/ stays
# as it is and switching between the two does not rebuild all dependencies.
export CARGO_TARGET_DIR="${REPO_ROOT}/target/llvm-cov-target"
eval "$(cargo llvm-cov show-env --sh)"
# This variable would suppress instrumentation in the cargo calls below.
unset CARGO_LLVM_COV_SHOW_ENV

echo "==> Removing old coverage data"
cargo llvm-cov clean --workspace

echo "==> Building the instrumented binary"
cargo build
BIN="${CARGO_LLVM_COV_TARGET_DIR}/debug/k8s-scale-app-rs"

echo "==> Running unit and Rust integration tests"
cargo test

echo "==> Running VTest2 tests"
# Every process the tests start writes its profile next to the others.
export LLVM_PROFILE_FILE
run_vtest "${BIN}"

echo "==> Coverage report (unit + integration + VTest2)"
# cargo llvm-cov report only knows the binaries it ran itself, so the profiles
# of the VTest2 runs go through the LLVM tools directly.
LLVM_BIN="$(rustc --print sysroot)/lib/rustlib/$(rustc --print host-tuple)/bin"
PROFDATA="${CARGO_LLVM_COV_TARGET_DIR}/merged.profdata"
"${LLVM_BIN}/llvm-profdata" merge "${CARGO_LLVM_COV_TARGET_DIR}"/*.profraw -o "${PROFDATA}"

OBJECTS=(--object "${BIN}")
while IFS= read -r -d '' obj; do
    OBJECTS+=(--object "${obj}")
done < <(find "${CARGO_LLVM_COV_TARGET_DIR}/debug/deps" -maxdepth 1 -type f -executable -print0)

if [[ "${HTML}" == true ]]; then
    HTML_DIR="${REPO_ROOT}/target/llvm-cov/html"
    "${LLVM_BIN}/llvm-cov" show --format=html --instr-profile="${PROFDATA}" \
        --output-dir="${HTML_DIR}" "${OBJECTS[@]}" --sources "${REPO_ROOT}/src"
    echo "    HTML report: ${HTML_DIR}/index.html"
else
    "${LLVM_BIN}/llvm-cov" report --instr-profile="${PROFDATA}" \
        "${OBJECTS[@]}" --sources "${REPO_ROOT}/src"
    "${LLVM_BIN}/llvm-cov" show --instr-profile="${PROFDATA}" "${OBJECTS[@]}" \
        --sources "${REPO_ROOT}/src" --show-line-counts-or-regions=false --format=text \
        | grep -E '^ +[0-9]+\| +0\|' || true
fi
