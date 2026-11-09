#!/usr/bin/env bash
set -Eeuo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t remnacust-detection.XXXXXXXX)
trap '[[ $fixture == /tmp/remnacust-detection.* ]] && rm -rf -- "$fixture"' EXIT
source "$project/installer.sh"
ROOT="$fixture/root"; WORK="$fixture/work"; LOG="$fixture/log"
mkdir -p "$WORK" "$ROOT/registry" "$ROOT/panel"
docker() { return 1; }
! component_installed panel
printf 'FROM scratch\n' > "$ROOT/panel/Dockerfile"
component_installed panel
show_menu > "$fixture/menu"
grep -q uninstall-panel "$fixture/menu"
grep -q install-node "$fixture/menu"
grep -A 1 'upgrade-node' "$fixture/menu" | grep -qi 'не установлена'
if (ROOT="$fixture/absent"; main upgrade-panel --yes) > "$fixture/missing.log" 2>&1; then exit 1; fi
grep -q 'не установлен' "$fixture/missing.log"
printf 'PASS directory and Docker file change only the matching install action; absent upgrade is blocked\n'
docker() { printf '%s\n' "${PAGE_TEST_IMAGE:-}"; }
ROOT="$fixture/page-root"
mkdir -p "$ROOT/registry/subscription-pages" "$ROOT/custom-page"
printf '{}\n' > "$ROOT/custom-page/docker-compose.yml"
! subscription_page_installed
show_menu > "$fixture/page-menu"
grep -A 1 'upgrade-subscription-page' "$fixture/page-menu" | grep -qi 'не установлена'
grep -A 1 'uninstall-subscription-page' "$fixture/page-menu" | grep -qi 'не установлена'
python3 - "$ROOT" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);item={'directory':str(root/'custom-page'),'composeFiles':[str(root/'custom-page/docker-compose.yml')]}
(root/'registry/subscription-pages/page.json').write_text(json.dumps(item))
PY
subscription_page_installed
python3 - "$ROOT/registry/subscription-pages/page.json" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]);item=json.loads(path.read_text());item['uninstalled']=True;path.write_text(json.dumps(item))
PY
! subscription_page_installed
printf '{"directory":null}\n' > "$ROOT/registry/subscription-pages/broken.json"
printf '{"subscriptionPage":false}\n' > "$ROOT/registry/panel.json"
! subscription_page_installed
python3 - "$ROOT" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);item={'directory':str(root/'custom-page'),'composeFiles':[str(root/'custom-page/docker-compose.yml')],'subscriptionPage':True}
(root/'registry/panel.json').write_text(json.dumps(item))
PY
subscription_page_installed
printf '{"subscriptionPage":false}\n' > "$ROOT/registry/panel.json"
PAGE_TEST_IMAGE='ghcr.io/lottman/remnacust-node:fixture'
! subscription_page_installed
PAGE_TEST_IMAGE='ghcr.io/lottman/remnacust-subscription-page:fixture'
subscription_page_installed
printf 'PASS page menu detects standalone, companion and stopped pages; absent, removed and malformed records stay unavailable\n'
WORK=''
