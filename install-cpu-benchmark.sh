#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_VERSION="1.1.1"
readonly DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/cpu-benchmark.sh"
readonly INSTALL_PATH="/usr/local/bin/cpu-benchmark"

log() {
    printf '[cpu-benchmark installer] %s\n' "$*"
}

warn() {
    printf '[cpu-benchmark installer] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[cpu-benchmark installer] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ ${1:-} == "--version" ]]; then
    printf 'cpu-benchmark installer %s\n' "$INSTALLER_VERSION"
    exit 0
fi

if (( EUID != 0 )); then
    die "This installer must be run as root (try: sudo bash install-cpu-benchmark.sh)."
fi

[[ -r /etc/os-release ]] || die "Cannot detect this operating system: /etc/os-release is missing."
# shellcheck disable=SC1091
source /etc/os-release

distribution=""
if command -v pveversion >/dev/null 2>&1 || [[ -d /etc/pve ]]; then
    distribution="Proxmox VE"
elif [[ ${ID:-} == "ubuntu" || ${ID_LIKE:-} == *ubuntu* ]]; then
    distribution="Ubuntu"
elif [[ ${ID:-} == "debian" || ${ID_LIKE:-} == *debian* ]]; then
    distribution="Debian"
else
    die "Unsupported distribution '${PRETTY_NAME:-${ID:-unknown}}'. Use Debian, Ubuntu, or Proxmox VE."
fi

command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
log "Detected ${distribution}: ${PRETTY_NAME:-unknown version}"
log "Updating APT package indexes..."
apt-get update

export DEBIAN_FRONTEND=noninteractive

package_available() {
    local package=$1
    apt-cache show "$package" >/dev/null 2>&1
}

install_required() {
    local package=$1

    package_available "$package" || die "Required package '$package' is unavailable in the configured APT repositories."
    log "Installing required package: $package"
    apt-get install -y --no-install-recommends "$package" || die "Failed to install required package '$package'."
}

install_optional() {
    local package=$1

    if ! package_available "$package"; then
        warn "Optional package '$package' is unavailable; skipping it."
        return 0
    fi

    log "Installing optional package: $package"
    if ! apt-get install -y --no-install-recommends "$package"; then
        warn "Optional package '$package' could not be installed; continuing."
    fi
}

for package in sysbench stress-ng util-linux python3; do
    install_required "$package"
done

# Package names differ between Debian, Ubuntu releases, and Proxmox kernels.
# Installing every available provider is intentional; failures here must not
# prevent the core sysbench benchmark from being installed.
optional_packages=(
    linux-perf
    perf
    linux-tools-common
    "linux-tools-$(uname -r)"
    linux-tools-generic
    linux-cpupower
    turbostat
)

declare -A seen_packages=()
for package in "${optional_packages[@]}"; do
    [[ -n ${seen_packages[$package]:-} ]] && continue
    seen_packages[$package]=1
    install_optional "$package"
done

temporary_script=""
cleanup() {
    if [[ -n $temporary_script && -f $temporary_script ]]; then
        rm -f -- "$temporary_script"
    fi
}
trap cleanup EXIT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)
source_script="${script_dir}/cpu-benchmark.sh"

if [[ ! -f $source_script ]]; then
    source_url=${CPU_BENCHMARK_SOURCE_URL:-$DEFAULT_SOURCE_URL}
    temporary_script=$(mktemp)
    log "Downloading cpu-benchmark from $source_url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --output "$temporary_script" "$source_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$temporary_script" "$source_url"
    else
        die "Neither curl nor wget is installed, and cpu-benchmark.sh was not found beside the installer."
    fi
    source_script=$temporary_script
fi

[[ -s $source_script ]] || die "The benchmark script is empty or missing."
bash -n "$source_script" || die "The benchmark script failed Bash syntax validation."

install -m 0755 "$source_script" "$INSTALL_PATH"
log "Installed cpu-benchmark to $INSTALL_PATH"
log "Run: cpu-benchmark --quick"
