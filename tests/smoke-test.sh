#!/usr/bin/env bash

# The single-quoted strings below are intentional script bodies for mock
# executables; their variables must expand when those mocks run, not here.
# shellcheck disable=SC2016

set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
mock_bin="${test_dir}/bin"
mkdir -p "$mock_bin"

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

write_mock() {
    local name=$1
    shift
    printf '%s\n' '#!/usr/bin/env bash' "$@" > "${mock_bin}/${name}"
    chmod +x "${mock_bin}/${name}"
}

write_mock uname \
    'if [[ ${1:-} == "-s" ]]; then printf "Linux\n"; else printf "Linux 6.8.0 mock x86_64\n"; fi'

write_mock hostname 'printf "benchmark-test-host\n"'

write_mock lscpu \
    'case "$*" in' \
    '  "-p=CPU,ONLINE") printf "# CPU,ONLINE\n0,Y\n1,Y\n" ;;' \
    '  "-p=SOCKET,CORE,ONLINE") printf "# SOCKET,CORE,ONLINE\n0,0,Y\n0,1,Y\n" ;;' \
    '  *) printf "Model name: Mock CPU 9000\nSocket(s): 1\nThread(s) per core: 1\n" ;;' \
    'esac'

write_mock taskset \
    '[[ ${1:-} == "-c" ]] || exit 2' \
    'shift 2' \
    'exec "$@"'

write_mock sysbench \
    'printf "%s\n" "events per second: 1234.50" "total time:                          1.0000s" "total number of events:              1235"'

write_mock perf \
    'if [[ ${MOCK_OPTIONAL_FAIL:-0} == 1 ]]; then' \
    '  printf "%s\n" "<not supported>;;cycles;0;100.00" "<not supported>;;instructions;0;100.00" "<not supported>;;cache-misses;0;100.00" "<not supported>;;branch-misses;0;100.00" >&2' \
    '  exit 1' \
    'fi' \
    'printf "%s\n" "1000000;;cycles;0;100.00" "2000000;;instructions;0;100.00" "3000;;cache-misses;0;100.00" "400;;branch-misses;0;100.00" >&2'

write_mock turbostat \
    'output=""' \
    'while (( $# > 0 )); do' \
    '  if [[ $1 == "--out" ]]; then output=$2; shift 2; continue; fi' \
    '  shift' \
    'done' \
    'if [[ ${MOCK_OPTIONAL_FAIL:-0} == 1 ]]; then exit 1; fi' \
    'printf "Bzy_MHz PkgWatt PkgTmp\n3456 42.50 71\n" > "$output"'

write_mock stress-ng \
    'if [[ ${MOCK_OPTIONAL_FAIL:-0} == 1 ]]; then exit 1; fi' \
    'printf "stress-ng: metrc: [1] cpu 5000 5.00 9.00 0.10 1000.00 550.00\n"'

write_mock cpupower 'printf "current policy: frequency should be within 800 MHz and 4.20 GHz.\n"'

write_mock python3 'exec python "$@"'

export PATH="${mock_bin}:${PATH}"

bash -n "${repo_dir}/install-cpu-benchmark.sh" "${repo_dir}/cpu-benchmark.sh"
[[ $(bash "${repo_dir}/cpu-benchmark.sh" --version) == "cpu-benchmark 1.0.0" ]]

bash "${repo_dir}/cpu-benchmark.sh" --quick --output "${test_dir}/success.json" > "${test_dir}/success-console.log"
python - "${test_dir}/success.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)

assert report["system"]["logical_cpus"] == 2
assert report["benchmarks"]["sysbench_cpu"]["single_core"]["events_per_second"] == 1234.5
assert len(report["benchmarks"]["sysbench_cpu"]["per_logical_cpu"]) == 2
assert report["performance_counters"]["ipc"] == 2.0
assert report["turbostat"]["package_watts"] == 42.5
assert report["turbostat"]["package_temperature_c"] == 71.0
assert report["turbostat"]["effective_mhz"] == 3456.0
assert report["benchmarks"]["stress_ng"]["bogo_operations_per_second"] == 1000.0
PY

MOCK_OPTIONAL_FAIL=1 bash "${repo_dir}/cpu-benchmark.sh" --full --output "${test_dir}/optional-failures.json" > "${test_dir}/optional-failures-console.log"
python - "${test_dir}/optional-failures.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)

assert report["benchmarks"]["sysbench_cpu"]["all_logical_cpus"]["status"] == "ok"
assert report["mode"] == "full"
assert report["performance_counters"]["status"] == "unavailable"
assert report["turbostat"]["status"] == "unavailable"
assert report["benchmarks"]["stress_ng"]["status"] == "error"
PY

printf 'Smoke tests passed.\n'
