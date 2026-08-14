# CPU Benchmark Toolkit

A reusable, non-invasive CPU benchmarking toolkit for Debian, Ubuntu,
Proxmox VE, Windows through WSL, and macOS. It measures sysbench single-core,
all-logical-CPU, and per-logical-CPU performance and adds Linux hardware
telemetry when the kernel and processor expose it.

The toolkit never changes the CPU governor, frequency limits, power limits, or
other tuning settings. It does not use or install Docker.

## One-line installation

```bash
curl -fsSL https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/install-cpu-benchmark.sh | sudo bash
```

When already logged in as root, as is common on Proxmox VE, omit `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/install-cpu-benchmark.sh | bash
```

From a cloned checkout, the installer uses the adjacent `cpu-benchmark.sh`:

```bash
sudo bash install-cpu-benchmark.sh
```

The installer supports Debian, Ubuntu, and Proxmox VE. It runs `apt-get update`,
installs the required benchmark tools, and installs the command as
`/usr/local/bin/cpu-benchmark`. Optional `perf`, `cpupower`, and `turbostat`
packages vary by distribution and kernel; unavailable packages are skipped.
`lm-sensors` is installed when available as an additional temperature source.

## Usage

```bash
# Short run; writes JSON and a text summary under /root/cpu-benchmarks/
sudo cpu-benchmark --quick

# Longer run with more stable samples
sudo cpu-benchmark --full

# Write to a different directory
sudo cpu-benchmark --quick --output /var/tmp/cpu-results

# Choose the exact JSON filename (the text summary is saved beside it)
cpu-benchmark --quick --output "$HOME/cpu-result.json"

# Opt in to submitting the completed report to ggwp.eu
sudo cpu-benchmark --quick --upload

# Use another compatible ingestion endpoint
sudo cpu-benchmark --full --upload-url https://example.net/api/CpuBenchmarks

# Retry a previously saved report without rerunning the benchmark
cpu-benchmark --submit /root/cpu-benchmarks/cpu-benchmark-20260814T120000Z.json

# Show or update the installed version
cpu-benchmark --version
sudo cpu-benchmark --update
```

`--full` can take a while on systems with many logical CPUs because every
online logical CPU receives an individual pinned run. Progress is written to
the console as each measurement starts.

## Platform notes

- **Debian, Ubuntu, and Proxmox VE:** fully supported. Linux per-CPU tests are
  pinned with `taskset`. Hardware counters use `perf`; package power,
  temperature, and effective MHz use `turbostat` when supported. In containers
  and restricted services, only CPUs allowed by the current cgroup/cpuset are
  benchmarked. If `taskset` is missing or affinity is blocked, single/all-CPU
  tests still run unpinned and only the per-CPU affinity results are marked
  unsupported.
- **Windows:** run the installer and benchmark inside a Debian or Ubuntu WSL
  distribution. WSL is detected and reported as platform `windows` with the
  `windows-wsl` environment. During a separate all-core workload, the script
  uses Windows PowerShell 5 or PowerShell 7 interop to estimate effective MHz
  from Windows Processor Information counters. Both CIM and legacy WMI queries
  are supported, as are standard and custom Windows drive mount locations. WSL
  scores include Windows scheduling and
  virtualization effects, so compare them only with other WSL results produced
  under similar Windows power and workload conditions.
- **Windows temperature:** Windows does not provide a dependable built-in CPU
  package-temperature API. To include it, start
  [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
  or OpenHardwareMonitor as administrator on Windows before running the WSL
  benchmark. The toolkit reads only CPU Package/Tdie/Tctl values from its WMI
  provider; it does not substitute ACPI, GPU, storage, or motherboard sensors.
  The toolkit does not install or start third-party Windows monitoring software.
- **macOS:** install Python 3 and sysbench (for example with Homebrew), then run
  `bash cpu-benchmark.sh --quick --output "$HOME/cpu-results"`. The benchmark
  script is compatible with the system Bash 3.2 and reports aggregate
  `sysctl` frequency data when macOS exposes it.
  macOS has no `taskset`, so per-logical-CPU affinity, Linux perf counters, and
  turbostat fields are explicitly marked unavailable.

## Output

Each run creates a readable `.txt` summary and a structured `.json` report.
The JSON contains:

- CPU model, architecture, sockets, physical cores, logical CPUs, and threads
  per core
- Per-CPU frequency, governor, and driver data from Linux sysfs
- Available hwmon and thermal-zone temperatures
- Optional normalized `lm-sensors -j` temperatures with their source
- Single-core, all-CPU, and per-logical-CPU sysbench results
- cycles, instructions, calculated IPC, cache misses, and branch misses
- turbostat package watts, package temperature, and effective MHz
- Windows host effective MHz and optional hardware-monitor CPU temperature when
  running under WSL
- stress-ng status and metrics when available

Restricted performance counters, unsupported CPUs, virtual machines, missing
sensors, and unavailable optional tools do not abort the benchmark. Their JSON
sections use `null` values with `unavailable` or `partial` status.

For unusual WSL mounts, set `CPU_BENCHMARK_POWERSHELL` to a Windows
`powershell.exe` or `pwsh.exe` path. Container operators can set
`CPU_BENCHMARK_CPU_LIST` to an explicit Linux CPU/range list such as `0-3,8`,
or set `CPU_BENCHMARK_DISABLE_AFFINITY=1` when affinity calls are prohibited.

## Uploading results

Uploading is always opt-in. `--upload` submits the completed JSON report to
`https://ggwp.eu/api/CpuBenchmarks`; `--upload-url URL` targets a compatible
endpoint and implies `--upload`. `--submit JSON` uploads an existing report
without rerunning the benchmark. The endpoint stores commonly queried system,
topology, score, IPC, power, temperature, and clock values as typed database
columns while retaining the full report as PostgreSQL `jsonb` for optional and
future metrics.

Reports contain the machine hostname and hardware details shown in the local
JSON. The server also records the request IP address. If an upload fails, the
local JSON and text files remain intact and the command returns a non-zero exit
status so automation can retry the same report ID safely.

To test a development checkout without installing it:

```bash
bash -n install-cpu-benchmark.sh cpu-benchmark.sh
tests/smoke-test.sh
./cpu-benchmark.sh --version
./cpu-benchmark.sh --help
```
