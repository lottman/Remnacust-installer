#!/usr/bin/env bash
set -Eeuo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t remnacust-detection.XXXXXXXX)
trap '[[ $fixture == /tmp/remnacust-detection.* ]] && rm -rf -- "$fixture"' EXIT
source "$project/installer.sh"
ROOT="$fixture/root"; WORK="$fixture/work"; LOG="$fixture/log"
mkdir -p "$WORK" "$ROOT/registry" "$ROOT/panel"
! component_installed panel
printf 'FROM scratch\n' > "$ROOT/panel/Dockerfile"
component_installed panel
show_menu > "$fixture/menu"
grep -q uninstall-panel "$fixture/menu"
grep -q install-node "$fixture/menu"
grep -q 'upgrade-node.*не установлена' "$fixture/menu"
if (ROOT="$fixture/absent"; main upgrade-panel --yes) > "$fixture/missing.log" 2>&1; then exit 1; fi
grep -q 'не установлен' "$fixture/missing.log"
printf 'PASS directory and Docker file change only the matching install action; absent upgrade is blocked\n'
STATE="$ROOT/registry/panel.json"; DEPLOY="$ROOT/panel"; HELPER="$project/runtime.py"
printf '{"component":"panel","directory":"%s","ownedServices":["app","db","caddy"]}' "$DEPLOY" > "$STATE"
APPS=(app); EXTRAS=(caddy); YES=true
compose() { printf '%s\n' "$*" >> "$fixture/requests"; }
uninstall_component >/dev/null
grep -qx 'stop app db caddy' "$fixture/requests"
grep -qx 'rm --force app db caddy' "$fixture/requests"
! grep -qE 'down|volume|prune|--volumes' "$fixture/requests"
[[ -f $DEPLOY/Dockerfile && -f $DEPLOY/.remnacust-uninstalled ]]
! component_installed panel
printf 'PASS uninstall removes only recorded services and preserves configuration and volumes\n'
WORK=''
