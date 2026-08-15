#!/usr/bin/env bash

set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)

cleanup() {
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

run_case() {
    local name=$1 os_id=$2 id_like=$3 pretty_name=$4 manager=$5 family=$6 python_package=$7
    local os_release="${test_dir}/${name}.os-release"
    local output="${test_dir}/${name}.output"

    printf 'ID=%s\nID_LIKE="%s"\nPRETTY_NAME="%s"\n' \
        "$os_id" "$id_like" "$pretty_name" > "$os_release"

    CPU_BENCHMARK_OS_RELEASE=$os_release \
    CPU_BENCHMARK_PACKAGE_MANAGER=$manager \
        bash "${repo_dir}/install-cpu-benchmark.sh" --dry-run \
        --install-path "/opt/cpu-benchmark-${name}" > "$output"

    grep -q "Detected ${family}: ${pretty_name}" "$output"
    grep -q "Package manager: ${manager}" "$output"
    grep -Eq "Would install package: .*sysbench" "$output"
    grep -q "Would install package: ${python_package}" "$output"
    grep -q "Would install cpu-benchmark to /opt/cpu-benchmark-${name}" "$output"
}

run_case debian debian "" "Debian GNU/Linux 13" apt "Debian family" python3
run_case ubuntu ubuntu debian "Ubuntu 26.04 LTS" apt "Ubuntu family" python3
run_case mint linuxmint "ubuntu debian" "Linux Mint 23" apt "Ubuntu family" python3
run_case fedora fedora "" "Fedora Linux 44" dnf "Fedora/RHEL family" python3
run_case rocky rocky rhel "Rocky Linux 10" dnf "Fedora/RHEL family" python3
run_case amazon amzn fedora "Amazon Linux 2023" dnf "Amazon Linux" python3
run_case arch arch "" "Arch Linux" pacman "Arch family" python
run_case manjaro manjaro arch "Manjaro Linux" pacman "Arch family" python
run_case opensuse opensuse-tumbleweed suse "openSUSE Tumbleweed" zypper "openSUSE/SUSE family" python3
run_case alpine alpine "" "Alpine Linux v3.22" apk "Alpine Linux" python3
run_case void void "" "Void Linux" xbps "Void Linux" python3
run_case gentoo gentoo "" "Gentoo Linux" emerge "Gentoo Linux" dev-lang/python
run_case openwrt openwrt "" "OpenWrt 24" opkg "OpenWrt" python3

unknown_release="${test_dir}/unknown.os-release"
printf 'ID=gentoo\nPRETTY_NAME="Gentoo Linux"\n' > "$unknown_release"
CPU_BENCHMARK_OS_RELEASE=$unknown_release \
    bash "${repo_dir}/install-cpu-benchmark.sh" --dry-run --portable \
    --install-path /opt/cpu-benchmark-gentoo > "${test_dir}/gentoo.output"
grep -q "Skipping package installation as requested" "${test_dir}/gentoo.output"

missing_release="${test_dir}/does-not-exist"
CPU_BENCHMARK_OS_RELEASE=$missing_release \
    CPU_BENCHMARK_PACKAGE_MANAGER=none \
    bash "${repo_dir}/install-cpu-benchmark.sh" --dry-run --portable \
    --install-path /opt/cpu-benchmark-minimal > "${test_dir}/minimal.output"
grep -q "Detected unknown Linux" "${test_dir}/minimal.output"

if CPU_BENCHMARK_OS_RELEASE=$unknown_release CPU_BENCHMARK_PACKAGE_MANAGER=brew \
    bash "${repo_dir}/install-cpu-benchmark.sh" --dry-run >/dev/null 2>&1; then
    printf 'Unsupported package manager override unexpectedly succeeded.\n' >&2
    exit 1
fi

printf 'Installer plan tests passed.\n'
