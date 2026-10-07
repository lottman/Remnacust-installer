#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bash "$root/installer/tests/bootstrap.sh"
bash "$root/installer/tests/service-state.sh"
bash "$root/installer/tests/supported-os.sh"
bash "$root/installer/tests/detection.sh"
bash "$root/installer/tests/uninstall.sh"
bash "$root/installer/tests/reinstall.sh"
bash "$root/installer/tests/preflight.sh"
bash "$root/installer/tests/certificate-workflow.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/installer/tests/test_network.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/installer/tests/test_input.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/installer/tests/test_tls.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/installer/tests/test_installer.py"
