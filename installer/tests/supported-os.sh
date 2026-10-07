#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/installer.sh"
fixture=$(mktemp -d)
trap 'rm -f -- "$fixture/os-release" "$fixture/result"; rmdir -- "$fixture"' EXIT
for pair in '22.04 jammy' '24.04 noble' '26.04 resolute'; do
    read -r version codename <<< "$pair"
    printf 'ID=ubuntu\nVERSION_ID="%s"\nVERSION_CODENAME=untrusted\n' "$version" > "$fixture/os-release"
    [[ $(supported_ubuntu_codename "$fixture/os-release") == "$codename" ]]
    printf 'PASS Ubuntu %s uses the matching Docker repository\n' "$version"
done
for pair in 'ubuntu 20.04' 'ubuntu 24.10' 'ubuntu 26.10' 'ubuntu 28.04' 'debian 12' 'debian 13' 'linuxmint 22'; do
    read -r id version <<< "$pair"
    printf 'ID=%s\nID_LIKE=ubuntu\nVERSION_ID="%s"\n' "$id" "$version" > "$fixture/os-release"
    if (supported_ubuntu_codename "$fixture/os-release") > "$fixture/result" 2>&1; then
        printf 'FAIL accepted %s %s\n' "$id" "$version"; exit 1
    fi
    grep -q 'Поддерживаются только Ubuntu 22.04 LTS, Ubuntu 24.04 LTS и Ubuntu 26.04 LTS' "$fixture/result"
    printf 'PASS %s %s is rejected\n' "$id" "$version"
done
printf 'ID=ubuntu\n' > "$fixture/os-release"
export VERSION_ID=24.04
if (supported_ubuntu_codename "$fixture/os-release") > "$fixture/result" 2>&1; then exit 1; fi
grep -q 'неизвестно' "$fixture/result"
printf 'PASS missing version fails with a readable error\n'
(
    supported_ubuntu_codename() { return 1; }
    step() { printf 'FAIL package manager was called\n'; exit 9; }
    command() { printf 'FAIL host commands were called\n'; exit 9; }
    if prepare_host; then exit 1; else [[ $? == 1 ]]; fi
)
printf 'PASS unsupported OS stops before package and Docker changes\n'
if [[ $EUID != 0 ]]; then
    if (
        supported_ubuntu_codename() { printf noble; }
        prepare_host
    ) > "$fixture/result" 2>&1; then exit 1; fi
    grep -q 'Для установки нужен root на Linux' "$fixture/result"
    printf 'PASS supported OS still requires root for installation\n'
fi
