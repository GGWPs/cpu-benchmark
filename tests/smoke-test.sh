#!/usr/bin/env bash

# The single-quoted strings below are intentional script bodies for mock
# executables; their variables must expand when those mocks run, not here.
# shellcheck disable=SC2016

set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
mock_bin="${test_dir}/bin"
upload_server_pid=""
mkdir -p "$mock_bin"

cleanup() {
    if [[ -n $upload_server_pid ]]; then
        kill "$upload_server_pid" 2>/dev/null || true
    fi
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

write_mock powershell.exe \
    'printf "%s\n" '\''{"status":"ok","processor_frequency_mhz":4200,"percent_processor_performance":118,"current_clock_mhz":4200,"maximum_clock_mhz":4200,"effective_mhz":4956,"clock_source":"windows_processor_information","cpu_temperature_c":63.5,"temperature_source":"root\\LibreHardwareMonitor/CPU Package","reason":null}'\'''

export PATH="${mock_bin}:${PATH}"

bash -n "${repo_dir}/install-cpu-benchmark.sh" "${repo_dir}/cpu-benchmark.sh"
[[ $(bash "${repo_dir}/install-cpu-benchmark.sh" --version) == "cpu-benchmark installer 1.2.0" ]]
[[ $(bash "${repo_dir}/cpu-benchmark.sh" --version) == "cpu-benchmark 1.2.0" ]]
! grep -Eq '^readonly VERSION=' "${repo_dir}/install-cpu-benchmark.sh"

upload_port_file="${test_dir}/upload-port"
upload_capture="${test_dir}/uploaded-reports.jsonl"
python - "$upload_port_file" "$upload_capture" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

port_file = Path(sys.argv[1])
capture_file = Path(sys.argv[2])
request_count = 0


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        global request_count
        request_count += 1
        length = int(self.headers.get("Content-Length", "0"))
        report = json.loads(self.rfile.read(length))
        with capture_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(report) + "\n")
        if request_count == 1:
            response = json.dumps({"reportId": report["report_id"]}).encode()
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
        else:
            self.send_response(409)
            self.end_headers()

    def log_message(self, format, *args):
        return


server = HTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="ascii")
server.handle_request()
server.handle_request()
server.server_close()
PY
upload_server_pid=$!

for _attempt in {1..50}; do
    [[ -s $upload_port_file ]] && break
    sleep 0.1
done
[[ -s $upload_port_file ]]
upload_port=$(<"$upload_port_file")
upload_url="http://127.0.0.1:${upload_port}/api/CpuBenchmarks"

bash "${repo_dir}/cpu-benchmark.sh" --quick --output "${test_dir}/success.json" \
    --upload-url "$upload_url" > "${test_dir}/success-console.log"
bash "${repo_dir}/cpu-benchmark.sh" --submit "${test_dir}/success.json" \
    --upload-url "$upload_url" > "${test_dir}/resubmit-console.log"
wait "$upload_server_pid"
upload_server_pid=""

python - "${test_dir}/success.json" <<'PY'
import json
import sys
import uuid

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)

uuid.UUID(report["report_id"])
assert report["system"]["logical_cpus"] == 2
assert report["benchmarks"]["sysbench_cpu"]["single_core"]["events_per_second"] == 1234.5
assert len(report["benchmarks"]["sysbench_cpu"]["per_logical_cpu"]) == 2
assert report["performance_counters"]["ipc"] == 2.0
assert report["turbostat"]["package_watts"] == 42.5
assert report["turbostat"]["package_temperature_c"] == 71.0
assert report["turbostat"]["effective_mhz"] == 3456.0
assert report["benchmarks"]["stress_ng"]["bogo_operations_per_second"] == 1000.0
PY

python - "${test_dir}/success.json" "$upload_capture" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    expected = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    submitted = [json.loads(line) for line in handle]

assert submitted == [expected, expected]
PY

CPU_BENCHMARK_FORCE_WSL=1 MOCK_OPTIONAL_FAIL=1 bash "${repo_dir}/cpu-benchmark.sh" \
    --quick --output "${test_dir}/wsl.json" > "${test_dir}/wsl-console.log"
python - "${test_dir}/wsl.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)

assert report["system"]["platform"] == "windows"
assert report["system"]["environment"] == "windows-wsl"
assert report["turbostat"]["status"] == "unavailable"
assert report["windows_host_telemetry"]["status"] == "ok"
assert report["windows_host_telemetry"]["effective_mhz"] == 4956
assert report["windows_host_telemetry"]["cpu_temperature_c"] == 63.5
assert any("WSL scores" in note for note in report["notes"])
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
