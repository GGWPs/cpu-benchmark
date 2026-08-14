#!/usr/bin/env bash

# Optional probes are deliberately allowed to fail. The benchmark's primary
# contract is to leave a useful JSON report even on virtualized or restricted
# hardware where perf, turbostat, cpufreq, or thermal sensors are unavailable.
set -uo pipefail

readonly VERSION="1.3.0"
readonly DEFAULT_UPDATE_URL="https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/cpu-benchmark.sh"
readonly DEFAULT_UPLOAD_URL="https://ggwp.eu/api/CpuBenchmarks"

MODE="quick"
OUTPUT_PATH=""
SUBMIT_PATH=""
UPLOAD=false
UPLOAD_URL=${CPU_BENCHMARK_UPLOAD_URL:-$DEFAULT_UPLOAD_URL}
TEMP_DIR=""

usage() {
    cat <<'USAGE'
Usage: cpu-benchmark [OPTIONS]

Benchmark CPU performance and capture system, frequency, thermal, perf, and
turbostat telemetry in both a console summary and a structured JSON report.

Options:
  --quick          Short benchmark (default)
  --full           Longer, more stable benchmark
  --output PATH    Output directory, or an explicit .json report path
  --upload         Submit the completed JSON report to ggwp.eu
  --upload-url URL Submit to a different compatible endpoint (implies --upload)
  --submit JSON    Submit an existing report without running a benchmark
  --update         Replace this script with the current GitHub version
  --version        Print the version and exit
  -h, --help       Show this help

The script never changes CPU governors, frequency limits, or power limits.
USAGE
}

log() {
    printf '[cpu-benchmark] %s\n' "$*" >&2
}

warn() {
    printf '[cpu-benchmark] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[cpu-benchmark] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

update_script() {
    local update_url temporary target
    update_url=${CPU_BENCHMARK_UPDATE_URL:-$DEFAULT_UPDATE_URL}
    temporary=$(mktemp) || die "Could not create an update temporary file."
    TEMP_DIR=""

    log "Downloading current script from $update_url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --output "$temporary" "$update_url" || {
            rm -f -- "$temporary"
            die "Update download failed."
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$temporary" "$update_url" || {
            rm -f -- "$temporary"
            die "Update download failed."
        }
    else
        rm -f -- "$temporary"
        die "Updating requires curl or wget."
    fi

    if ! head -n 1 "$temporary" | grep -Eq '^#!.*bash'; then
        rm -f -- "$temporary"
        die "Downloaded file does not look like a Bash script."
    fi
    if ! bash -n "$temporary"; then
        rm -f -- "$temporary"
        die "Downloaded update failed Bash syntax validation."
    fi

    target=$0
    if command -v cpu-benchmark >/dev/null 2>&1; then
        target=$(command -v cpu-benchmark)
    fi
    if [[ ! -w $target && $EUID -ne 0 ]]; then
        rm -f -- "$temporary"
        die "Updating '$target' requires root; rerun with sudo."
    fi

    install -m 0755 "$temporary" "$target" || {
        rm -f -- "$temporary"
        die "Could not install the update to '$target'."
    }
    rm -f -- "$temporary"
    printf 'Updated cpu-benchmark at %s\n' "$target"
}

upload_report() {
    local response

    log "Uploading JSON report to $UPLOAD_URL"
    export VERSION UPLOAD_URL JSON_PATH
    if ! response=$(python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

url = os.environ["UPLOAD_URL"]
if not url.startswith(("https://", "http://")):
    print("upload URL must use http:// or https://", file=sys.stderr)
    raise SystemExit(2)

with open(os.environ["JSON_PATH"], "rb") as handle:
    payload = handle.read()

request = urllib.request.Request(
    url,
    data=payload,
    method="POST",
    headers={
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": f"cpu-benchmark/{os.environ['VERSION']}",
    },
)

try:
    with urllib.request.urlopen(request, timeout=30) as result:
        body = result.read().decode("utf-8", errors="replace")
        receipt = json.loads(body) if body else {}
        report_id = receipt.get("reportId") or receipt.get("report_id") or "accepted"
        print(f"submitted ({report_id})")
except urllib.error.HTTPError as error:
    body = error.read().decode("utf-8", errors="replace").strip()
    if error.code == 409:
        print("already submitted")
        raise SystemExit(0)
    print(f"server returned HTTP {error.code}: {body[:500]}", file=sys.stderr)
    raise SystemExit(1)
except (urllib.error.URLError, TimeoutError, ValueError) as error:
    print(f"upload failed: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
    ); then
        warn "Upload failed; the local JSON report remains available at $JSON_PATH."
        if [[ -n ${SUMMARY_PATH:-} && -f $SUMMARY_PATH ]]; then
            printf 'Upload:             failed (%s)\n' "$UPLOAD_URL" | tee -a "$SUMMARY_PATH"
        else
            printf 'Upload: failed (%s)\n' "$UPLOAD_URL"
        fi
        return 1
    fi

    if [[ -n ${SUMMARY_PATH:-} && -f $SUMMARY_PATH ]]; then
        printf 'Upload:             %s to %s\n' "$response" "$UPLOAD_URL" | tee -a "$SUMMARY_PATH"
    else
        printf 'Upload: %s to %s\n' "$response" "$UPLOAD_URL"
    fi
}

while (( $# > 0 )); do
    case $1 in
        --quick)
            MODE="quick"
            ;;
        --full)
            MODE="full"
            ;;
        --output)
            (( $# >= 2 )) || die "--output requires a path."
            OUTPUT_PATH=$2
            shift
            ;;
        --upload)
            UPLOAD=true
            ;;
        --upload-url)
            (( $# >= 2 )) || die "--upload-url requires a URL."
            UPLOAD_URL=$2
            UPLOAD=true
            shift
            ;;
        --submit)
            (( $# >= 2 )) || die "--submit requires a JSON report path."
            SUBMIT_PATH=$2
            UPLOAD=true
            shift
            ;;
        --version)
            printf 'cpu-benchmark %s\n' "$VERSION"
            exit 0
            ;;
        --update)
            update_script
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help)"
            ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || die "python3 is required to create the JSON report."

if [[ -n $SUBMIT_PATH ]]; then
    JSON_PATH=$SUBMIT_PATH
    SUMMARY_PATH="${JSON_PATH%.json}.txt"
    [[ -r $JSON_PATH ]] || die "Cannot read JSON report '$JSON_PATH'."
    upload_report || exit 1
    exit 0
fi

command -v sysbench >/dev/null 2>&1 || die "sysbench is required (run install-cpu-benchmark.sh first)."

case $(uname -s 2>/dev/null || printf unknown) in
    Linux*) RUNTIME_PLATFORM="linux" ;;
    Darwin*) RUNTIME_PLATFORM="macos" ;;
    MINGW*|MSYS*|CYGWIN*) RUNTIME_PLATFORM="windows" ;;
    *) RUNTIME_PLATFORM="unknown" ;;
esac

IS_WSL=false
if [[ $RUNTIME_PLATFORM == "linux" ]] && {
    [[ ${CPU_BENCHMARK_FORCE_WSL:-0} == "1" ]] ||
        [[ -n ${WSL_INTEROP:-} ]] ||
        [[ -n ${WSL_DISTRO_NAME:-} ]] ||
        grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null
}; then
    IS_WSL=true
fi

PLATFORM=$RUNTIME_PLATFORM
ENVIRONMENT="native"
if [[ $IS_WSL == true ]]; then
    PLATFORM="windows"
    ENVIRONMENT="windows-wsl"
fi

TASKSET_AVAILABLE=false
if [[ $RUNTIME_PLATFORM == "linux" ]] &&
    [[ ${CPU_BENCHMARK_DISABLE_AFFINITY:-0} != "1" ]] &&
    command -v taskset >/dev/null 2>&1; then
    TASKSET_AVAILABLE=true
fi

if [[ -z $OUTPUT_PATH && $EUID -ne 0 ]]; then
    die "The default output is /root/cpu-benchmarks; run as root or provide --output PATH."
fi

if [[ $MODE == "quick" ]]; then
    SINGLE_DURATION=3
    MULTI_DURATION=3
    PER_CPU_DURATION=1
    STRESS_DURATION=5
else
    SINGLE_DURATION=15
    MULTI_DURATION=15
    PER_CPU_DURATION=5
    STRESS_DURATION=30
fi

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
FILE_TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
if [[ -z $OUTPUT_PATH ]]; then
    OUTPUT_DIR="/root/cpu-benchmarks"
    JSON_PATH="${OUTPUT_DIR}/cpu-benchmark-${FILE_TIMESTAMP}.json"
elif [[ $OUTPUT_PATH == *.json ]]; then
    JSON_PATH=$OUTPUT_PATH
    OUTPUT_DIR=$(dirname -- "$JSON_PATH")
else
    OUTPUT_DIR=$OUTPUT_PATH
    JSON_PATH="${OUTPUT_DIR}/cpu-benchmark-${FILE_TIMESTAMP}.json"
fi
SUMMARY_PATH="${JSON_PATH%.json}.txt"

mkdir -p -- "$OUTPUT_DIR" || die "Could not create output directory '$OUTPUT_DIR'."
TEMP_DIR=$(mktemp -d) || die "Could not create a temporary directory."

SYSTEM_TSV="${TEMP_DIR}/system.tsv"
SYSBENCH_TSV="${TEMP_DIR}/sysbench.tsv"
PERF_TSV="${TEMP_DIR}/perf.tsv"
TURBOSTAT_RAW="${TEMP_DIR}/turbostat.raw"
WINDOWS_TELEMETRY_RAW="${TEMP_DIR}/windows-host-telemetry.json"
STRESS_TSV="${TEMP_DIR}/stress.tsv"
CPUPOWER_RAW="${TEMP_DIR}/cpupower.raw"
SENSORS_RAW="${TEMP_DIR}/sensors.json"
: > "$SYSTEM_TSV"
: > "$SYSBENCH_TSV"
: > "$PERF_TSV"
: > "$TURBOSTAT_RAW"
printf '{"status":"unavailable","reason":"not_wsl"}\n' > "$WINDOWS_TELEMETRY_RAW"
: > "$STRESS_TSV"
: > "$CPUPOWER_RAW"
: > "$SENSORS_RAW"

sanitize_field() {
    printf '%s' "$1" | tr '\t\r\n' '   '
}

system_value() {
    printf '%s\t%s\n' "$1" "$(sanitize_field "$2")" >> "$SYSTEM_TSV"
}

first_nonempty() {
    awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }'
}

make_cpu_sequence() {
    local count=$1 index=0 result=""
    while (( index < count )); do
        if [[ -z $result ]]; then
            result=$index
        else
            result="${result},${index}"
        fi
        (( index += 1 ))
    done
    printf '%s\n' "$result"
}

expand_cpu_list() {
    local ranges=$1

    awk -v ranges="$ranges" 'BEGIN {
        count = split(ranges, parts, ",")
        for (part = 1; part <= count; part++) {
            range_count = split(parts[part], bounds, "-")
            start = bounds[1]
            finish = range_count == 2 ? bounds[2] : start
            if (start !~ /^[0-9]+$/ || finish !~ /^[0-9]+$/ || finish < start) {
                continue
            }
            for (cpu = start; cpu <= finish; cpu++) {
                printf "%s%d", separator, cpu
                separator = ","
            }
        }
        print ""
    }'
}

detect_linux_cpu_list() {
    local allowed="" detected=""

    if [[ -n ${CPU_BENCHMARK_CPU_LIST:-} ]]; then
        detected=$(expand_cpu_list "$CPU_BENCHMARK_CPU_LIST")
        if [[ -n $detected ]]; then
            printf '%s\n' "$detected"
            return 0
        fi
    fi

    if [[ -r /proc/self/status ]]; then
        allowed=$(awk '/^Cpus_allowed_list:/ {print $2; exit}' /proc/self/status 2>/dev/null)
        if [[ -n $allowed ]]; then
            detected=$(expand_cpu_list "$allowed")
        fi
    fi

    if [[ -z $detected ]] && command -v lscpu >/dev/null 2>&1; then
        detected=$(LC_ALL=C lscpu -p=CPU,ONLINE 2>/dev/null |
            awk -F, '!/^#/ && ($2 == "Y" || $2 == "") {printf "%s%s", separator, $1; separator=","}')
    fi

    if [[ -z $detected ]]; then
        detected=$(make_cpu_sequence "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)")
    fi

    printf '%s\n' "${detected:-0}"
}

collect_system_information() {
    local logical=1 physical=1 sockets=1 threads=1 model="unknown" cpu_list="0"
    local restricted_sockets="" topology=""

    case $RUNTIME_PLATFORM in
        linux)
            cpu_list=$(detect_linux_cpu_list)
            logical=$(awk -F, '{print NF}' <<< "$cpu_list")
            if command -v lscpu >/dev/null 2>&1; then
                model=$(LC_ALL=C lscpu | awk -F: '/^Model name:/ {sub(/^[ \t]+/, "", $2); print $2; exit}')
                topology=$(LC_ALL=C lscpu -p=CPU,SOCKET,CORE,ONLINE 2>/dev/null |
                    awk -F, -v allowed="$cpu_list" 'BEGIN {
                        count = split(allowed, cpus, ",")
                        for (item = 1; item <= count; item++) permit[cpus[item]] = 1
                    }
                    !/^#/ && ($4 == "Y" || $4 == "") && ($1 in permit) {
                        cores[$2 ":" $3]=1
                        socket_ids[$2]=1
                    }
                    END {
                        for (core in cores) core_total++
                        for (socket_id in socket_ids) socket_total++
                        print core_total+0, socket_total+0
                    }')
                read -r physical restricted_sockets <<< "$topology"
                if [[ $restricted_sockets =~ ^[0-9]+$ ]] && (( restricted_sockets > 0 )); then
                    sockets=$restricted_sockets
                fi
                threads=$(LC_ALL=C lscpu | awk -F: '/^Thread\(s\) per core:/ {gsub(/[ \t]/, "", $2); print $2; exit}')
            fi
            if [[ -z $model || $model == "unknown" ]]; then
                model=$(awk -F: '/model name|Hardware|Processor/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
            fi
            ;;
        macos)
            model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null || printf unknown)
            logical=$(sysctl -n hw.logicalcpu 2>/dev/null || printf 1)
            physical=$(sysctl -n hw.physicalcpu 2>/dev/null || printf '%s' "$logical")
            sockets=$(sysctl -n hw.packages 2>/dev/null || printf 1)
            (( physical > 0 )) && threads=$(( logical / physical ))
            cpu_list=$(make_cpu_sequence "$logical")
            ;;
        windows)
            if command -v powershell.exe >/dev/null 2>&1; then
                model=$(powershell.exe -NoProfile -Command '(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name).Trim()' 2>/dev/null | tr -d '\r' | first_nonempty)
                logical=$(powershell.exe -NoProfile -Command '(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum' 2>/dev/null | tr -d '\r' | first_nonempty)
                physical=$(powershell.exe -NoProfile -Command '(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum' 2>/dev/null | tr -d '\r' | first_nonempty)
                sockets=$(powershell.exe -NoProfile -Command '(Get-CimInstance Win32_Processor).Count' 2>/dev/null | tr -d '\r' | first_nonempty)
            fi
            logical=${logical:-${NUMBER_OF_PROCESSORS:-1}}
            physical=${physical:-$logical}
            sockets=${sockets:-1}
            (( physical > 0 )) && threads=$(( logical / physical ))
            cpu_list=$(make_cpu_sequence "$logical")
            ;;
        *)
            logical=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
            physical=$logical
            cpu_list=$(make_cpu_sequence "$logical")
            ;;
    esac

    [[ $logical =~ ^[0-9]+$ ]] && (( logical > 0 )) || logical=1
    [[ $physical =~ ^[0-9]+$ ]] && (( physical > 0 )) || physical=$logical
    [[ $sockets =~ ^[0-9]+$ ]] && (( sockets > 0 )) || sockets=1
    [[ $threads =~ ^[0-9]+$ ]] && (( threads > 0 )) || threads=1
    if [[ $RUNTIME_PLATFORM == "linux" ]] &&
        (( physical > 0 && logical >= physical && logical % physical == 0 )); then
        threads=$(( logical / physical ))
    fi
    [[ -n $cpu_list ]] || cpu_list=$(make_cpu_sequence "$logical")

    CPU_MODEL=${model:-unknown}
    LOGICAL_CPUS=$logical
    PHYSICAL_CORES=$physical
    SOCKETS=$sockets
    THREADS_PER_CORE=$threads
    CPU_LIST=$cpu_list

    system_value platform "$PLATFORM"
    system_value environment "$ENVIRONMENT"
    system_value architecture "$(uname -m 2>/dev/null || printf unknown)"
    system_value hostname "$(hostname 2>/dev/null || printf unknown)"
    system_value kernel "$(uname -srvm 2>/dev/null || printf unknown)"
    system_value cpu_model "$CPU_MODEL"
    system_value sockets "$SOCKETS"
    system_value physical_cores "$PHYSICAL_CORES"
    system_value logical_cpus "$LOGICAL_CPUS"
    system_value threads_per_core "$THREADS_PER_CORE"
    system_value online_cpu_list "$CPU_LIST"
    if [[ $RUNTIME_PLATFORM == "linux" && -r /etc/os-release ]]; then
        system_value os_release "$(awk -F= '/^PRETTY_NAME=/{value=substr($0,index($0,"=")+1); gsub(/^"|"$/, "", value); print value}' /etc/os-release)"
    else
        system_value os_release "$(uname -s 2>/dev/null || printf unknown)"
    fi
    if [[ $RUNTIME_PLATFORM == "macos" ]]; then
        system_value frequency_current_hz "$(sysctl -n hw.cpufrequency 2>/dev/null || true)"
        system_value frequency_minimum_hz "$(sysctl -n hw.cpufrequency_min 2>/dev/null || true)"
        system_value frequency_maximum_hz "$(sysctl -n hw.cpufrequency_max 2>/dev/null || true)"
    fi
}

parse_sysbench_value() {
    local pattern=$1 file=$2
    awk -v pattern="$pattern" '$0 ~ pattern {print $NF; exit}' "$file" 2>/dev/null
}

record_sysbench() {
    local kind=$1 cpu_id=$2 threads=$3 duration=$4 affinity=$5
    local raw="${TEMP_DIR}/sysbench-${kind}-${cpu_id:-all}.raw"
    local status="ok" error="" eps="" events="" elapsed="" rc=0
    local -a command=(sysbench cpu --cpu-max-prime=20000 --threads="$threads" --time="$duration" run)

    if [[ -n $affinity ]]; then
        command=(taskset -c "$affinity" "${command[@]}")
    fi

    log "Running ${kind} sysbench (${threads} thread(s), ${duration}s)..."
    LC_ALL=C "${command[@]}" > "$raw" 2>&1 || rc=$?
    eps=$(parse_sysbench_value 'events per second:' "$raw")
    events=$(parse_sysbench_value 'total number of events:' "$raw")
    elapsed=$(awk '/total time:/ {gsub(/s/, "", $3); print $3; exit}' "$raw" 2>/dev/null)
    if (( rc != 0 )) || [[ -z $eps ]]; then
        status="error"
        error=$(tail -n 3 "$raw" 2>/dev/null | tr '\n\t' '  ')
        warn "${kind} sysbench did not produce a score${cpu_id:+ for CPU $cpu_id}."
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$cpu_id" "$threads" "$eps" "$events" "$elapsed" "$status" "$(sanitize_field "$error")" >> "$SYSBENCH_TSV"
}

record_unsupported_per_cpu() {
    local cpu_id
    IFS=',' read -r -a cpu_ids <<< "$CPU_LIST"
    for cpu_id in "${cpu_ids[@]}"; do
        printf 'per_cpu\t%s\t1\t\t\t\tunsupported\t%s\n' \
            "$cpu_id" "CPU affinity via taskset is only available on Linux" >> "$SYSBENCH_TSV"
    done
}

run_perf() {
    local raw="${TEMP_DIR}/perf.raw" rc=0 value unit event runtime percentage
    local -a workload=(sysbench cpu --cpu-max-prime=20000 --threads="$LOGICAL_CPUS" --time="$MULTI_DURATION" run)

    if [[ $RUNTIME_PLATFORM != "linux" ]] || ! command -v perf >/dev/null 2>&1; then
        printf 'status\t\tunavailable\n' >> "$PERF_TSV"
        return 0
    fi
    if [[ $TASKSET_AVAILABLE == true ]]; then
        workload=(taskset -c "$CPU_LIST" "${workload[@]}")
    fi
    log "Collecting perf hardware counters..."
    LC_ALL=C perf stat -x ';' -e cycles,instructions,cache-misses,branch-misses -- \
        "${workload[@]}" >/dev/null 2> "$raw" || rc=$?

    while IFS=';' read -r value unit event runtime percentage _rest; do
        value=$(printf '%s' "$value" | tr -d ' ')
        event=$(printf '%s' "$event" | tr -d ' ')
        case $event in
            cycles|instructions|cache-misses|branch-misses)
                if [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                    printf '%s\t%s\tok\n' "$event" "$value" >> "$PERF_TSV"
                else
                    printf '%s\t\tunsupported\n' "$event" >> "$PERF_TSV"
                fi
                ;;
        esac
        : "$unit" "$runtime" "$percentage"
    done < "$raw"

    for event in cycles instructions cache-misses branch-misses; do
        if ! awk -F '\t' -v name="$event" '$1 == name {found=1} END {exit !found}' "$PERF_TSV"; then
            printf '%s\t\tunsupported\n' "$event" >> "$PERF_TSV"
        fi
    done
    if (( rc != 0 )); then
        warn "perf counters were unavailable or restricted; the report will retain supported counters only."
    fi
}

run_turbostat() {
    local rc=0 diagnostic="${TEMP_DIR}/turbostat-error.raw"
    local -a workload=(sysbench cpu --cpu-max-prime=20000 --threads="$LOGICAL_CPUS" --time="$MULTI_DURATION" run)

    if [[ $RUNTIME_PLATFORM != "linux" ]] || ! command -v turbostat >/dev/null 2>&1; then
        printf 'unavailable\n' > "$TURBOSTAT_RAW"
        return 0
    fi

    if [[ $TASKSET_AVAILABLE == true ]]; then
        workload=(taskset -c "$CPU_LIST" "${workload[@]}")
    fi

    log "Collecting turbostat package power, temperature, and effective MHz..."
    LC_ALL=C turbostat --quiet --Summary --show Bzy_MHz,PkgWatt,PkgTmp \
        --out "$TURBOSTAT_RAW" "${workload[@]}" >/dev/null 2> "$diagnostic" || rc=$?
    if (( rc != 0 )); then
        warn "turbostat is unsupported on this CPU, blocked by the hypervisor, or missing required kernel access."
    fi
}

find_windows_powershell() {
    local candidate windows_path

    if [[ -n ${CPU_BENCHMARK_POWERSHELL:-} ]]; then
        if command -v "$CPU_BENCHMARK_POWERSHELL" >/dev/null 2>&1; then
            command -v "$CPU_BENCHMARK_POWERSHELL"
            return 0
        fi
        if [[ -x $CPU_BENCHMARK_POWERSHELL ]]; then
            printf '%s\n' "$CPU_BENCHMARK_POWERSHELL"
            return 0
        fi
        return 1
    fi

    for candidate in powershell.exe pwsh.exe; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    if command -v wslpath >/dev/null 2>&1; then
        for windows_path in \
            'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' \
            'C:\Program Files\PowerShell\7\pwsh.exe'; do
            candidate=$(wslpath -u "$windows_path" 2>/dev/null | tr -d '\r')
            if [[ -n $candidate && -x $candidate ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    fi

    for candidate in \
        /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
        /mnt/c/Program\ Files/PowerShell/7/pwsh.exe \
        /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
        /c/Program\ Files/PowerShell/7/pwsh.exe; do
        if [[ -x $candidate ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

collect_windows_host_telemetry() {
    [[ $IS_WSL == true ]] || return 0

    local powershell_path powershell_script diagnostic workload_pid rc=0
    local telemetry_duration=$MULTI_DURATION
    local -a workload
    diagnostic="${TEMP_DIR}/windows-host-telemetry-error.raw"
    (( telemetry_duration >= 5 )) || telemetry_duration=5

    if ! powershell_path=$(find_windows_powershell); then
        printf '{"status":"unavailable","reason":"powershell_interop_unavailable"}\n' > "$WINDOWS_TELEMETRY_RAW"
        warn "WSL was detected, but Windows PowerShell interop is unavailable."
        return 0
    fi

    powershell_script=$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false

function Get-CompatibleInstance {
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Namespace = 'root\cimv2'
    )

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            return @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
        } catch {
        }
    }
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        try {
            return @(Get-WmiObject -Namespace $Namespace -Class $ClassName -ErrorAction Stop)
        } catch {
        }
    }
    return @()
}

$result = [ordered]@{
    status = 'unavailable'
    processor_frequency_mhz = $null
    percent_processor_performance = $null
    current_clock_mhz = $null
    maximum_clock_mhz = $null
    effective_mhz = $null
    clock_source = $null
    cpu_temperature_c = $null
    temperature_source = $null
    reason = $null
}

try {
    $processors = @(Get-CompatibleInstance -ClassName Win32_Processor)
    if ($processors.Count -gt 0) {
        $result.current_clock_mhz = [Math]::Round(
            [double](($processors | Measure-Object -Property CurrentClockSpeed -Average).Average), 3)
        $result.maximum_clock_mhz = [Math]::Round(
            [double](($processors | Measure-Object -Property MaxClockSpeed -Maximum).Maximum), 3)
    }
} catch {
}

try {
    $performanceRows = @(Get-CompatibleInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation)
    $selectedRows = @($performanceRows | Where-Object Name -eq '_Total')
    if ($selectedRows.Count -eq 0) {
        $selectedRows = @($performanceRows | Where-Object Name -match '^[0-9]+,_Total$')
    }
    if ($selectedRows.Count -eq 0) {
        $selectedRows = @($performanceRows | Where-Object Name -notmatch '_Total$')
    }
    if ($selectedRows.Count -gt 0) {
        $frequency = [double](($selectedRows |
            Measure-Object -Property ProcessorFrequency -Average).Average)
        $percent = [double](($selectedRows |
            Measure-Object -Property PercentProcessorPerformance -Average).Average)
        if ($frequency -gt 0) {
            $result.processor_frequency_mhz = [Math]::Round($frequency, 3)
        }
        if ($percent -gt 0) {
            $result.percent_processor_performance = [Math]::Round($percent, 3)
        }
        if ($frequency -gt 0 -and $percent -gt 0) {
            $result.effective_mhz = [Math]::Round($frequency * $percent / 100.0, 3)
            $result.clock_source = 'windows_processor_information'
        }
    }
} catch {
}

if ($null -eq $result.effective_mhz -and $result.current_clock_mhz -gt 0) {
    $result.effective_mhz = $result.current_clock_mhz
    $result.clock_source = 'win32_processor_current_clock'
}

$temperatureCandidates = @()
foreach ($namespace in @('root\LibreHardwareMonitor', 'root\OpenHardwareMonitor')) {
    try {
        $sensors = @(Get-CompatibleInstance -Namespace $namespace -ClassName Sensor)
        foreach ($sensor in $sensors) {
            if ([string]$sensor.SensorType -ne 'Temperature' -or $null -eq $sensor.Value) {
                continue
            }

            $parent = [string]$sensor.Parent
            $identifier = [string]$sensor.Identifier
            if ($parent -notmatch '^/(amd|intel)cpu/' -and $identifier -notmatch '^/(amd|intel)cpu/') {
                continue
            }

            $name = [string]$sensor.Name
            $priority = 100
            if ($name -match '^CPU Package$' -or $name -match '^Package') {
                $priority = 1
            } elseif ($name -match 'Tdie') {
                $priority = 2
            } elseif ($name -match 'Tctl') {
                $priority = 3
            }

            if ($priority -lt 100) {
                $temperatureCandidates += [pscustomobject]@{
                    Priority = $priority
                    Value = [double]$sensor.Value
                    Source = "$namespace/$name"
                }
            }
        }
    } catch {
    }
}

$temperature = $temperatureCandidates |
    Sort-Object -Property Priority, @{ Expression = 'Value'; Descending = $true } |
    Select-Object -First 1
if ($null -ne $temperature) {
    $result.cpu_temperature_c = [Math]::Round($temperature.Value, 3)
    $result.temperature_source = $temperature.Source
}

if ($null -ne $result.effective_mhz -and $null -ne $result.cpu_temperature_c) {
    $result.status = 'ok'
} elseif ($null -ne $result.effective_mhz) {
    $result.status = 'partial'
    $result.reason = 'hardware_monitor_temperature_unavailable'
} elseif ($null -ne $result.cpu_temperature_c) {
    $result.status = 'partial'
    $result.reason = 'windows_processor_counters_unavailable'
} else {
    $result.reason = 'windows_counters_and_hardware_monitor_unavailable'
}

[Console]::Out.Write(($result | ConvertTo-Json -Compress))
POWERSHELL
)

    workload=(sysbench cpu --cpu-max-prime=20000 \
        --threads="$LOGICAL_CPUS" --time="$telemetry_duration" run)
    if [[ $TASKSET_AVAILABLE == true ]]; then
        workload=(taskset -c "$CPU_LIST" "${workload[@]}")
    fi
    log "Collecting Windows host clock and optional hardware-monitor temperature from WSL..."
    LC_ALL=C "${workload[@]}" >/dev/null 2>&1 &
    workload_pid=$!
    "$powershell_path" -NoLogo -NoProfile -NonInteractive -Command "$powershell_script" \
        > "$WINDOWS_TELEMETRY_RAW" 2> "$diagnostic" || rc=$?
    wait "$workload_pid" 2>/dev/null || true

    if (( rc != 0 )) || [[ ! -s $WINDOWS_TELEMETRY_RAW ]]; then
        printf '{"status":"unavailable","reason":"windows_telemetry_command_failed"}\n' > "$WINDOWS_TELEMETRY_RAW"
        warn "Windows host telemetry could not be read through WSL interop."
    fi
}

run_stress_ng() {
    local raw="${TEMP_DIR}/stress-ng.raw" rc=0 bogo="" real_time="" status="ok"
    if [[ $RUNTIME_PLATFORM != "linux" ]] || ! command -v stress-ng >/dev/null 2>&1; then
        printf 'unavailable\t\t\n' > "$STRESS_TSV"
        return 0
    fi
    log "Running stress-ng CPU workload (${STRESS_DURATION}s)..."
    LC_ALL=C stress-ng --cpu "$LOGICAL_CPUS" --cpu-method all --timeout "${STRESS_DURATION}s" \
        --metrics-brief > "$raw" 2>&1 || rc=$?
    bogo=$(awk '{for (i=1; i<=NF; i++) if ($i == "cpu" && $(i+5) ~ /^[0-9]+([.][0-9]+)?$/) {print $(i+5); exit}}' "$raw")
    real_time=$(awk '{for (i=1; i<=NF; i++) if ($i == "cpu" && $(i+2) ~ /^[0-9]+([.][0-9]+)?$/) {print $(i+2); exit}}' "$raw")
    if (( rc != 0 )); then
        status="error"
        warn "stress-ng returned an error; continuing with the remaining results."
    fi
    printf '%s\t%s\t%s\n' "$status" "$bogo" "$real_time" > "$STRESS_TSV"
}

collect_cpupower() {
    if [[ $RUNTIME_PLATFORM == "linux" ]] && command -v cpupower >/dev/null 2>&1; then
        LC_ALL=C cpupower frequency-info > "$CPUPOWER_RAW" 2>&1 || true
    fi
}

collect_sensors_json() {
    if [[ $RUNTIME_PLATFORM == "linux" ]] && command -v sensors >/dev/null 2>&1; then
        LC_ALL=C sensors -j > "$SENSORS_RAW" 2>/dev/null || : > "$SENSORS_RAW"
    fi
}

collect_system_information
log "CPU: $CPU_MODEL"
log "Topology: ${SOCKETS} socket(s), ${PHYSICAL_CORES} physical core(s), ${LOGICAL_CPUS} logical CPU(s)"

IFS=',' read -r -a ONLINE_CPU_IDS <<< "$CPU_LIST"
FIRST_CPU=${ONLINE_CPU_IDS[0]:-0}
if [[ $TASKSET_AVAILABLE == true ]] && ! taskset -c "$FIRST_CPU" true >/dev/null 2>&1; then
    TASKSET_AVAILABLE=false
    warn "CPU affinity is not permitted in this environment; continuing without pinned runs."
fi
if [[ $RUNTIME_PLATFORM == "linux" && $TASKSET_AVAILABLE == true ]]; then
    record_sysbench single "$FIRST_CPU" 1 "$SINGLE_DURATION" "$FIRST_CPU"
    record_sysbench multi "" "$LOGICAL_CPUS" "$MULTI_DURATION" "$CPU_LIST"
    for cpu_id in "${ONLINE_CPU_IDS[@]}"; do
        record_sysbench per_cpu "$cpu_id" 1 "$PER_CPU_DURATION" "$cpu_id"
    done
else
    record_sysbench single "" 1 "$SINGLE_DURATION" ""
    record_sysbench multi "" "$LOGICAL_CPUS" "$MULTI_DURATION" ""
    record_unsupported_per_cpu
    warn "Per-logical-CPU affinity requires Linux taskset; per-CPU runs are marked unsupported on $PLATFORM."
fi

run_perf
run_turbostat
collect_windows_host_telemetry
run_stress_ng
collect_cpupower
collect_sensors_json

export VERSION MODE TIMESTAMP PLATFORM JSON_PATH SUMMARY_PATH
export SYSTEM_TSV SYSBENCH_TSV PERF_TSV TURBOSTAT_RAW WINDOWS_TELEMETRY_RAW STRESS_TSV CPUPOWER_RAW SENSORS_RAW

if ! python3 - <<'PY'
import glob
import json
import math
import os
import re
import socket
import uuid
from pathlib import Path


def number(value, integer=False):
    if value is None:
        return None
    value = str(value).strip().replace(",", "")
    try:
        return int(float(value)) if integer else float(value)
    except (TypeError, ValueError):
        return None


def read_tsv(path):
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                rows.append(line.rstrip("\n").split("\t"))
    except OSError:
        pass
    return rows


system = {row[0]: row[1] if len(row) > 1 else "" for row in read_tsv(os.environ["SYSTEM_TSV"])}

benchmarks = {"single_core": None, "all_logical_cpus": None, "per_logical_cpu": []}
for row in read_tsv(os.environ["SYSBENCH_TSV"]):
    row += [""] * (8 - len(row))
    result = {
        "cpu_id": number(row[1], integer=True),
        "threads": number(row[2], integer=True),
        "events_per_second": number(row[3]),
        "total_events": number(row[4], integer=True),
        "elapsed_seconds": number(row[5]),
        "status": row[6] or "unknown",
        "error": row[7] or None,
    }
    if row[0] == "single":
        benchmarks["single_core"] = result
    elif row[0] == "multi":
        benchmarks["all_logical_cpus"] = result
    elif row[0] == "per_cpu":
        benchmarks["per_logical_cpu"].append(result)

perf = {
    "status": "unavailable",
    "cycles": None,
    "instructions": None,
    "ipc": None,
    "cache_misses": None,
    "branch_misses": None,
}
perf_statuses = []
for row in read_tsv(os.environ["PERF_TSV"]):
    row += [""] * (3 - len(row))
    if row[0] == "status":
        perf_statuses.append(row[2] or row[1])
        continue
    key = row[0].replace("-", "_")
    if key in perf:
        perf[key] = number(row[1], integer=True)
        perf_statuses.append(row[2])
if perf["cycles"] and perf["instructions"]:
    perf["ipc"] = perf["instructions"] / perf["cycles"]
if any(status == "ok" for status in perf_statuses):
    perf["status"] = "partial" if any(status != "ok" for status in perf_statuses) else "ok"


def parse_turbostat(path):
    result = {
        "status": "unavailable",
        "package_watts": None,
        "package_temperature_c": None,
        "effective_mhz": None,
    }
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return result
    wanted = {"PkgWatt": "package_watts", "PkgTmp": "package_temperature_c", "Bzy_MHz": "effective_mhz"}
    header = None
    found = {}
    for line in lines:
        fields = line.split()
        if any(name in fields for name in wanted):
            header = fields
            continue
        if not header or len(fields) < len(header):
            continue
        for name, key in wanted.items():
            if name in header:
                candidate = number(fields[header.index(name)])
                if candidate is not None:
                    found[key] = candidate
    result.update(found)
    if found:
        result["status"] = "ok" if len(found) == len(wanted) else "partial"
    return result


def parse_windows_host_telemetry(path):
    result = {
        "status": "unavailable",
        "processor_frequency_mhz": None,
        "percent_processor_performance": None,
        "current_clock_mhz": None,
        "maximum_clock_mhz": None,
        "effective_mhz": None,
        "clock_source": None,
        "cpu_temperature_c": None,
        "temperature_source": None,
        "reason": None,
    }
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8-sig", errors="replace"))
    except (OSError, ValueError):
        result["reason"] = "invalid_or_missing_windows_telemetry"
        return result
    if not isinstance(payload, dict):
        result["reason"] = "invalid_windows_telemetry"
        return result
    for key in (
        "processor_frequency_mhz",
        "percent_processor_performance",
        "current_clock_mhz",
        "maximum_clock_mhz",
        "effective_mhz",
        "cpu_temperature_c",
    ):
        result[key] = number(payload.get(key))
    for key in ("clock_source", "temperature_source", "reason"):
        value = payload.get(key)
        result[key] = value if isinstance(value, str) and value else None
    status = payload.get("status")
    if status in {"ok", "partial", "unavailable"}:
        result["status"] = status
    return result


def collect_frequencies():
    records = []
    allowed_cpu_ids = {
        number(item, integer=True)
        for item in system.get("online_cpu_list", "").split(",")
        if item != ""
    }
    for cpu_dir in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*"), key=lambda p: number(re.search(r"cpu(\d+)$", p).group(1), True)):
        match = re.search(r"cpu(\d+)$", cpu_dir)
        if not match:
            continue
        cpu_id = int(match.group(1))
        if allowed_cpu_ids and cpu_id not in allowed_cpu_ids:
            continue
        cpufreq = Path(cpu_dir) / "cpufreq"
        if not cpufreq.exists():
            continue

        def read(name):
            try:
                return (cpufreq / name).read_text(encoding="ascii").strip()
            except OSError:
                return None

        records.append({
            "cpu_id": cpu_id,
            "current_mhz": (number(read("scaling_cur_freq")) or 0) / 1000 or None,
            "minimum_mhz": (number(read("scaling_min_freq")) or 0) / 1000 or None,
            "maximum_mhz": (number(read("scaling_max_freq")) or 0) / 1000 or None,
            "governor": read("scaling_governor"),
            "driver": read("scaling_driver"),
        })
    try:
        cpupower = Path(os.environ["CPUPOWER_RAW"]).read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        cpupower = ""
    aggregate = {
        "current_mhz": (number(system.get("frequency_current_hz")) or 0) / 1_000_000 or None,
        "minimum_mhz": (number(system.get("frequency_minimum_hz")) or 0) / 1_000_000 or None,
        "maximum_mhz": (number(system.get("frequency_maximum_hz")) or 0) / 1_000_000 or None,
    }
    has_aggregate = any(value is not None for value in aggregate.values())
    return {
        "status": "ok" if records or has_aggregate else "unavailable",
        "per_cpu": records,
        "aggregate": aggregate if has_aggregate else None,
        "cpupower_frequency_info": cpupower or None,
    }


def collect_temperatures():
    sensors = []
    seen = set()

    def add_sensor(device, label, temperature, source):
        if temperature is None or not (-273.15 <= temperature <= 1000):
            return
        key = (device, label, round(temperature, 3))
        if key not in seen:
            seen.add(key)
            sensors.append({
                "device": device,
                "label": label,
                "temperature_c": temperature,
                "source": source,
            })

    for input_path in glob.glob("/sys/class/hwmon/hwmon*/temp*_input"):
        path = Path(input_path)
        try:
            raw = number(path.read_text(encoding="ascii"))
        except OSError:
            continue
        if raw is None:
            continue
        temperature = raw / 1000
        label_path = path.with_name(path.name.replace("_input", "_label"))
        name_path = path.parent / "name"
        try:
            label = label_path.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            label = path.stem
        try:
            device = name_path.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            device = path.parent.name
        add_sensor(device, label, temperature, "hwmon-sysfs")
    for zone in glob.glob("/sys/class/thermal/thermal_zone*"):
        zone_path = Path(zone)
        try:
            raw = number((zone_path / "temp").read_text(encoding="ascii"))
            label = (zone_path / "type").read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if raw is None:
            continue
        add_sensor("thermal_zone", label, raw / 1000, "thermal-sysfs")

    try:
        sensors_data = json.loads(Path(os.environ["SENSORS_RAW"]).read_text(
            encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        sensors_data = {}
    if isinstance(sensors_data, dict):
        for device, features in sensors_data.items():
            if not isinstance(features, dict):
                continue
            normalized_device = re.sub(
                r"-(?:pci|isa|acpi|virtual)-.*$", "", str(device), flags=re.IGNORECASE)
            for label, values in features.items():
                if not isinstance(values, dict):
                    continue
                for key, value in values.items():
                    if re.match(r"^temp[0-9]+_input$", key):
                        add_sensor(normalized_device, str(label), number(value), "lm-sensors")
    return {"status": "ok" if sensors else "unavailable", "sensors": sensors}


stress_rows = read_tsv(os.environ["STRESS_TSV"])
stress_row = (stress_rows[0] if stress_rows else []) + [""] * 3
stress = {
    "status": stress_row[0] or "unavailable",
    "bogo_operations_per_second": number(stress_row[1]),
    "real_time_seconds": number(stress_row[2]),
}

single = benchmarks.get("single_core") or {}
multi = benchmarks.get("all_logical_cpus") or {}
single_eps = single.get("events_per_second")
multi_eps = multi.get("events_per_second")
scaling = (multi_eps / single_eps) if single_eps and multi_eps else None
turbostat = parse_turbostat(os.environ["TURBOSTAT_RAW"])
windows_host_telemetry = parse_windows_host_telemetry(os.environ["WINDOWS_TELEMETRY_RAW"])
notes = [
    "No CPU governor, frequency limit, or power limit was changed.",
    "Unavailable optional metrics are represented by null values and an unavailable or partial status.",
]
if system.get("environment") == "windows-wsl":
    notes.append(
        "WSL scores include Windows scheduling and virtualization effects and should only be compared with other WSL runs."
    )

report = {
    "report_id": str(uuid.uuid4()),
    "schema_version": 1,
    "tool": {"name": "cpu-benchmark", "version": os.environ["VERSION"]},
    "timestamp_utc": os.environ["TIMESTAMP"],
    "mode": os.environ["MODE"],
    "system": {
        "platform": system.get("platform"),
        "environment": system.get("environment") or "native",
        "architecture": system.get("architecture"),
        "os_release": system.get("os_release"),
        "hostname": system.get("hostname") or socket.gethostname(),
        "kernel": system.get("kernel"),
        "cpu_model": system.get("cpu_model"),
        "sockets": number(system.get("sockets"), integer=True),
        "physical_cores": number(system.get("physical_cores"), integer=True),
        "logical_cpus": number(system.get("logical_cpus"), integer=True),
        "threads_per_core": number(system.get("threads_per_core"), integer=True),
        "online_cpu_list": [number(item, integer=True) for item in system.get("online_cpu_list", "").split(",") if item != ""],
    },
    "frequency": collect_frequencies(),
    "temperatures": collect_temperatures(),
    "benchmarks": {
        "sysbench_cpu": benchmarks,
        "multi_to_single_scaling": scaling,
        "stress_ng": stress,
    },
    "performance_counters": perf,
    "turbostat": turbostat,
    "windows_host_telemetry": windows_host_telemetry,
    "notes": notes,
}

json_path = Path(os.environ["JSON_PATH"])
summary_path = Path(os.environ["SUMMARY_PATH"])
with json_path.open("w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=False)
    handle.write("\n")

per_cpu_scores = [item["events_per_second"] for item in benchmarks["per_logical_cpu"] if item.get("events_per_second") is not None]
temperatures = [item["temperature_c"] for item in report["temperatures"]["sensors"]]
current_clocks = [
    item["current_mhz"] for item in report["frequency"]["per_cpu"]
    if item.get("current_mhz") is not None
]
frequency_aggregate = report["frequency"].get("aggregate") or {}
reported_clock_mhz = (
    sum(current_clocks) / len(current_clocks)
    if current_clocks
    else frequency_aggregate.get("current_mhz")
)
cpu_temperature = (
    turbostat["package_temperature_c"]
    if turbostat["package_temperature_c"] is not None
    else windows_host_telemetry["cpu_temperature_c"]
)
effective_mhz = (
    turbostat["effective_mhz"]
    if turbostat["effective_mhz"] is not None
    else windows_host_telemetry["effective_mhz"]
)


def fmt(value, suffix="", precision=2):
    return "unavailable" if value is None else f"{value:.{precision}f}{suffix}"


lines = [
    "CPU Benchmark Summary",
    "=====================",
    f"Timestamp:          {report['timestamp_utc']}",
    f"Mode:               {report['mode']}",
    f"Platform:           {report['system']['platform']} ({report['system']['os_release']})",
    f"Environment:        {report['system']['environment']}",
    f"Architecture:       {report['system']['architecture']}",
    f"CPU:                {report['system']['cpu_model']}",
    f"Topology:           {report['system']['sockets']} socket(s), {report['system']['physical_cores']} physical core(s), {report['system']['logical_cpus']} logical CPU(s), {report['system']['threads_per_core']} thread(s)/core",
    "",
    "Performance",
    f"  Single core:      {fmt(single_eps, ' events/s')}",
    f"  All logical CPUs: {fmt(multi_eps, ' events/s')}",
    f"  Scaling:          {fmt(scaling, 'x')}",
]
if per_cpu_scores:
    lines.append(f"  Per-CPU range:    {min(per_cpu_scores):.2f} - {max(per_cpu_scores):.2f} events/s (mean {sum(per_cpu_scores) / len(per_cpu_scores):.2f})")
else:
    lines.append("  Per-CPU range:    unavailable")
lines.extend([
    "",
    "Hardware counters",
    f"  Cycles:           {perf['cycles'] if perf['cycles'] is not None else 'unavailable'}",
    f"  Instructions:     {perf['instructions'] if perf['instructions'] is not None else 'unavailable'}",
    f"  IPC:              {fmt(perf['ipc'])}",
    f"  Cache misses:     {perf['cache_misses'] if perf['cache_misses'] is not None else 'unavailable'}",
    f"  Branch misses:    {perf['branch_misses'] if perf['branch_misses'] is not None else 'unavailable'}",
    "",
    "Telemetry",
    f"  Package watts:    {fmt(report['turbostat']['package_watts'], ' W')}",
    f"  CPU temperature:  {fmt(cpu_temperature, ' C')}",
    f"  Effective clock:  {fmt(effective_mhz, ' MHz')}",
    f"  Current clock:    {fmt(reported_clock_mhz, ' MHz')}",
    f"  Max sensor temp:  {fmt(max(temperatures) if temperatures else None, ' C')}",
    "",
    f"JSON report:        {json_path}",
    f"Text summary:       {summary_path}",
])
summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
then
    die "Could not generate the JSON and text reports."
fi

cat "$SUMMARY_PATH"

if [[ $UPLOAD == true ]]; then
    upload_report || exit 1
fi
