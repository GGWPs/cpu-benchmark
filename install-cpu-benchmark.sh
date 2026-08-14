#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALLER_VERSION="1.4.0"
readonly DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/GGWPs/cpu-benchmark/main/cpu-benchmark.sh"
readonly DEFAULT_INSTALL_PATH="/usr/local/bin/cpu-benchmark"

SKIP_PACKAGES=false
DRY_RUN=false
SOURCE_URL=${CPU_BENCHMARK_SOURCE_URL:-}
INSTALL_PATH=${CPU_BENCHMARK_INSTALL_PATH:-$DEFAULT_INSTALL_PATH}
OS_RELEASE_FILE=${CPU_BENCHMARK_OS_RELEASE:-/etc/os-release}
PACKAGE_MANAGER=${CPU_BENCHMARK_PACKAGE_MANAGER:-}
temporary_script=""

usage() {
    cat <<'USAGE'
Usage: install-cpu-benchmark.sh [OPTIONS]

Install cpu-benchmark and its dependencies on supported Linux distributions.

Options:
  --source-url URL   Download the benchmark from URL instead of GitHub main
  --install-path PATH
                     Install the command at PATH (default: /usr/local/bin/cpu-benchmark)
  --skip-packages    Install only the script; do not use a package manager
  --dry-run          Show detected distribution and package plan without changes
  --version          Print the installer version and exit
  -h, --help         Show this help

Supported package managers: apt, dnf, yum, zypper, pacman, and apk.
The real installation requires root; --help, --version, and --dry-run do not.
USAGE
}

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

cleanup() {
    if [[ -n $temporary_script && -f $temporary_script ]]; then
        rm -f -- "$temporary_script"
    fi
}
trap cleanup EXIT

while (( $# > 0 )); do
    case $1 in
        --source-url|--source)
            (( $# >= 2 )) || die "$1 requires a URL."
            SOURCE_URL=$2
            shift
            ;;
        --install-path)
            (( $# >= 2 )) || die "--install-path requires a path."
            INSTALL_PATH=$2
            shift
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --version)
            printf 'cpu-benchmark installer %s\n' "$INSTALLER_VERSION"
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

if [[ $DRY_RUN != true ]] && (( EUID != 0 )); then
    die "This installer must be run as root (try: sudo bash install-cpu-benchmark.sh)."
fi

[[ -r $OS_RELEASE_FILE ]] || die "Cannot detect this operating system: '$OS_RELEASE_FILE' is missing."

os_release_value() {
    local key=$1
    awk -F= -v key="$key" '$1 == key {
        value=substr($0, index($0, "=") + 1)
        gsub(/^"|"$/, "", value)
        print value
        exit
    }' "$OS_RELEASE_FILE"
}

OS_ID=$(os_release_value ID)
OS_ID_LIKE=$(os_release_value ID_LIKE)
OS_PRETTY_NAME=$(os_release_value PRETTY_NAME)
OS_NAME=$(os_release_value NAME)
OS_PRETTY_NAME=${OS_PRETTY_NAME:-${OS_NAME:-${OS_ID:-unknown Linux}}}

if command -v pveversion >/dev/null 2>&1 || [[ -d /etc/pve ]]; then
    DISTRIBUTION="Proxmox VE"
elif [[ $OS_ID == "ubuntu" || $OS_ID_LIKE == *ubuntu* ]]; then
    DISTRIBUTION="Ubuntu family"
elif [[ $OS_ID == "debian" || $OS_ID_LIKE == *debian* ]]; then
    DISTRIBUTION="Debian family"
elif [[ $OS_ID == "amzn" ]]; then
    DISTRIBUTION="Amazon Linux"
elif [[ $OS_ID =~ ^(fedora|rhel|centos|rocky|almalinux|ol)$ || $OS_ID_LIKE == *rhel* || $OS_ID_LIKE == *fedora* ]]; then
    DISTRIBUTION="Fedora/RHEL family"
elif [[ $OS_ID =~ ^(arch|manjaro|endeavouros)$ || $OS_ID_LIKE == *arch* ]]; then
    DISTRIBUTION="Arch family"
elif [[ $OS_ID =~ ^(opensuse.*|sles)$ || $OS_ID_LIKE == *suse* ]]; then
    DISTRIBUTION="openSUSE/SUSE family"
elif [[ $OS_ID == "alpine" ]]; then
    DISTRIBUTION="Alpine Linux"
else
    DISTRIBUTION="$OS_PRETTY_NAME"
fi

detect_package_manager() {
    local candidate

    if [[ -n $PACKAGE_MANAGER ]]; then
        printf '%s\n' "$PACKAGE_MANAGER"
        return 0
    fi

    for candidate in apt-get dnf yum zypper pacman apk; do
        if command -v "$candidate" >/dev/null 2>&1; then
            case $candidate in
                apt-get) printf 'apt\n' ;;
                *) printf '%s\n' "$candidate" ;;
            esac
            return 0
        fi
    done
    return 1
}

if [[ $SKIP_PACKAGES != true ]]; then
    PACKAGE_MANAGER=$(detect_package_manager) || die \
        "No supported package manager found. Use --skip-packages after installing sysbench and python3 manually."
    case $PACKAGE_MANAGER in
        apt|dnf|yum|zypper|pacman|apk) ;;
        *) die "Unsupported package manager override '$PACKAGE_MANAGER'." ;;
    esac
else
    PACKAGE_MANAGER=${PACKAGE_MANAGER:-skipped}
fi

log "Detected ${DISTRIBUTION}: ${OS_PRETTY_NAME}"
log "Package manager: ${PACKAGE_MANAGER}"

run_package_update() {
    if [[ $DRY_RUN == true ]]; then
        log "Would refresh ${PACKAGE_MANAGER} package indexes."
        return 0
    fi

    log "Refreshing ${PACKAGE_MANAGER} package indexes..."
    case $PACKAGE_MANAGER in
        apt)
            apt-get update
            ;;
        dnf)
            dnf -y makecache
            ;;
        yum)
            yum -y makecache
            ;;
        zypper)
            zypper --non-interactive refresh
            ;;
        pacman)
            log "Pacman uses the currently configured sync databases to avoid an implicit partial system upgrade."
            ;;
        apk)
            apk update
            ;;
    esac
}

package_available() {
    local package=$1

    [[ $DRY_RUN == true ]] && return 0
    case $PACKAGE_MANAGER in
        apt) apt-cache show "$package" >/dev/null 2>&1 ;;
        dnf) dnf -q list --showduplicates "$package" >/dev/null 2>&1 ;;
        yum) yum -q list "$package" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive --no-refresh install --dry-run "$package" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$package" >/dev/null 2>&1 ;;
        apk) apk search -x "$package" 2>/dev/null | grep -q . ;;
    esac
}

install_package() {
    local package=$1

    if [[ $DRY_RUN == true ]]; then
        log "Would install package: $package"
        return 0
    fi

    case $PACKAGE_MANAGER in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package" ;;
        dnf) dnf install -y "$package" ;;
        yum) yum install -y "$package" ;;
        zypper) zypper --non-interactive install --no-recommends "$package" ;;
        pacman) pacman -S --needed --noconfirm "$package" ;;
        apk) apk add --no-cache "$package" ;;
    esac
}

install_required_candidates() {
    local capability=$1 package
    shift

    for package in "$@"; do
        if package_available "$package"; then
            log "Installing required ${capability}: $package"
            install_package "$package" && return 0
        fi
    done
    die "Required ${capability} is unavailable. Enable the distribution repository that provides: $*."
}

install_optional_candidates() {
    local capability=$1 package
    shift

    for package in "$@"; do
        if package_available "$package"; then
            log "Installing optional ${capability}: $package"
            if install_package "$package"; then
                return 0
            fi
        fi
    done
    warn "Optional ${capability} is unavailable; continuing without it."
    return 0
}

if [[ $SKIP_PACKAGES != true ]]; then
    run_package_update
    case $PACKAGE_MANAGER in
        apt)
            install_required_candidates "sysbench" sysbench
            install_required_candidates "Python 3" python3
            install_required_candidates "util-linux" util-linux
            install_optional_candidates "stress-ng" stress-ng
            install_optional_candidates "perf" linux-perf perf "linux-tools-$(uname -r)" linux-tools-generic
            install_optional_candidates "cpupower" linux-cpupower linux-tools-common "linux-tools-$(uname -r)"
            install_optional_candidates "turbostat" turbostat "linux-tools-$(uname -r)" linux-tools-generic
            install_optional_candidates "temperature sensors" lm-sensors
            ;;
        dnf|yum)
            install_required_candidates "sysbench" sysbench
            install_required_candidates "Python 3" python3
            install_required_candidates "util-linux" util-linux
            install_optional_candidates "stress-ng" stress-ng
            install_optional_candidates "perf" perf
            install_optional_candidates "cpupower/turbostat" kernel-tools
            install_optional_candidates "temperature sensors" lm_sensors
            ;;
        zypper)
            install_required_candidates "sysbench" sysbench
            install_required_candidates "Python 3" python3
            install_required_candidates "util-linux" util-linux
            install_optional_candidates "stress-ng" stress-ng
            install_optional_candidates "perf" perf
            install_optional_candidates "cpupower" cpupower
            install_optional_candidates "turbostat" turbostat
            install_optional_candidates "temperature sensors" sensors lm_sensors
            ;;
        pacman)
            install_required_candidates "sysbench" sysbench
            install_required_candidates "Python 3" python python3
            install_required_candidates "util-linux" util-linux
            install_optional_candidates "stress-ng" stress-ng
            install_optional_candidates "perf" perf
            install_optional_candidates "cpupower/turbostat" linux-tools
            install_optional_candidates "temperature sensors" lm_sensors
            ;;
        apk)
            install_required_candidates "sysbench" sysbench
            install_required_candidates "Python 3" python3
            install_required_candidates "util-linux" util-linux
            install_optional_candidates "stress-ng" stress-ng
            install_optional_candidates "perf" perf
            install_optional_candidates "cpupower/turbostat" linux-tools
            install_optional_candidates "temperature sensors" lm-sensors
            ;;
    esac
else
    log "Skipping package installation as requested."
fi

if [[ $DRY_RUN == true ]]; then
    log "Would install cpu-benchmark to $INSTALL_PATH"
    exit 0
fi

download_file() {
    local url=$1 destination=$2

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --output "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$url"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$url" "$destination" <<'PY'
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=30) as response:
    data = response.read()
with open(sys.argv[2], "wb") as output:
    output.write(data)
PY
    else
        return 1
    fi
}

script_dir=""
if ! script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P); then
    warn "Could not resolve the installer directory; the benchmark will be downloaded."
fi
source_script="${script_dir}/cpu-benchmark.sh"

if [[ -n $SOURCE_URL || ! -f $source_script ]]; then
    SOURCE_URL=${SOURCE_URL:-$DEFAULT_SOURCE_URL}
    temporary_script=$(mktemp)
    log "Downloading cpu-benchmark from $SOURCE_URL"
    download_file "$SOURCE_URL" "$temporary_script" || die \
        "Download failed; install curl, wget, or python3, or place cpu-benchmark.sh beside the installer."
    source_script=$temporary_script
fi

[[ -s $source_script ]] || die "The benchmark script is empty or missing."
head -n 1 "$source_script" | grep -Eq '^#!.*bash' || die "The benchmark script does not have a Bash shebang."
bash -n "$source_script" || die "The benchmark script failed Bash syntax validation."

install_directory=$(dirname -- "$INSTALL_PATH")
mkdir -p -- "$install_directory" || die "Could not create '$install_directory'."
if command -v install >/dev/null 2>&1; then
    install -m 0755 "$source_script" "$INSTALL_PATH"
else
    cp -- "$source_script" "$INSTALL_PATH"
    chmod 0755 "$INSTALL_PATH"
fi

log "Installed cpu-benchmark to $INSTALL_PATH"
if ! "$INSTALL_PATH" --check; then
    warn "Installation completed, but required runtime checks failed. Review the check output above."
fi
log "Run: cpu-benchmark --quick"
