# CPU Benchmark Toolkit

A reusable, non-invasive CPU benchmarking toolkit for Linux VPSs, dedicated
servers, containers, Proxmox VE, Windows through WSL, and macOS. It measures
single-core, all-logical-CPU, and per-logical-CPU performance and adds hardware
telemetry when the operating system, hypervisor, and processor expose it.

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

The installer automatically detects APT, DNF, YUM, Zypper, Pacman, APK, XBPS,
Portage, or OPKG. This
covers Debian, Ubuntu and their derivatives, Proxmox VE, Fedora, RHEL, Rocky,
AlmaLinux, CentOS, Oracle Linux, Amazon Linux, Arch, Manjaro, openSUSE, SUSE,
Alpine, Void, Gentoo, and OpenWrt. Unknown or very minimal Linux images receive
a script-only portable installation instead of being rejected. The installer
uses configured package indexes (refreshing them where safe),
installs the required benchmark tools, and installs the command as
`/usr/local/bin/cpu-benchmark`. Optional
`stress-ng`, `perf`, `cpupower`, `turbostat`, and sensor packages are installed
when the distribution provides them and never block the core installation.
If `sysbench` is unavailable, the benchmark automatically uses its bundled
Python CPU engine; reports identify the engine so unlike scores are not mixed.

Alpine does not include Bash by default, so bootstrap it first:

```sh
apk add --no-cache bash curl && curl -fsSL https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/install-cpu-benchmark.sh | bash
```

Useful installer options:

```bash
# Preview detection and packages without root or system changes
bash install-cpu-benchmark.sh --dry-run

# Install only the script when dependencies are already managed separately
curl -fsSL https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/install-cpu-benchmark.sh | sudo bash -s -- --skip-packages

# Portable alias for minimal, immutable, or custom VPS images
curl -fsSL https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/install-cpu-benchmark.sh | sudo bash -s -- --portable

# Custom destination or mirror/source
sudo bash install-cpu-benchmark.sh --install-path /opt/bin/cpu-benchmark
sudo bash install-cpu-benchmark.sh --source-url https://mirror.example/cpu-benchmark.sh
```

The installer does not enable third-party repositories. Only Bash and Python 3
are needed for the portable path. RHEL-family and other minimal systems use the
portable engine when their configured repositories do not provide `sysbench`.

## Usage

```bash
# Short run; root writes under /root/cpu-benchmarks/
sudo cpu-benchmark --quick

# Non-root runs need no extra option; output normally goes under ~/.local/state/
cpu-benchmark --quick

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

# Diagnose required tools and optional telemetry without running a benchmark
cpu-benchmark --check
cpu-benchmark --doctor --output "$HOME/cpu-results"
```

`--full` can take a while on systems with many logical CPUs because every
online logical CPU receives an individual pinned run. Progress is written to
the console as each measurement starts.

## Platform notes

- **Linux/VPS:** Debian/Ubuntu derivatives, Proxmox VE, Fedora/RHEL derivatives,
  Amazon Linux, Arch derivatives, openSUSE/SUSE, Alpine, Void, Gentoo, and
  OpenWrt have automatic package-manager support. Unknown distributions can use
  the portable installer. Linux per-CPU tests are pinned with `taskset`.
  Hardware counters use `perf`; package power,
  temperature, and effective MHz use `turbostat` when supported. In containers
  and restricted services, only CPUs allowed by the current cgroup/cpuset are
  benchmarked. If `taskset` is missing or affinity is blocked, single/all-CPU
  tests still run unpinned and only the per-CPU affinity results are marked
  unsupported.
- **Minimal and restricted VPSs:** missing `sysbench` selects the portable
  Python benchmark engine. Missing `taskset`, `perf`, `turbostat`, `cpupower`,
  `stress-ng`, sensor access, MSRs, or cpufreq data remains non-fatal. Reports
  include the detected VM/container environment and cgroup CPU quota where
  available. A non-root run automatically selects a user-writable output path.
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
- Benchmark engine plus single-core, all-CPU, and per-logical-CPU results
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
tests/installer-plan-test.sh
./cpu-benchmark.sh --version
./cpu-benchmark.sh --help
./cpu-benchmark.sh --check --output /tmp/cpu-results
```

GitHub Actions runs ShellCheck plus the installer-plan and benchmark smoke
suites on both Ubuntu and macOS. The installer-plan suite covers Debian,
Ubuntu, Mint, Fedora, Rocky, Amazon Linux, Arch, Manjaro, openSUSE, Alpine, and
manual package-management mode without requiring Docker.
