#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bash "$root/installer/tests/bootstrap.sh"
bash "$root/installer/tests/service-state.sh"
bash "$root/installer/tests/supported-os.sh"
bash "$root/installer/tests/detection.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/installer/tests/test_installer.py"
