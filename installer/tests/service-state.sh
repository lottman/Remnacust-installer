#!/usr/bin/env bash
# No Docker daemon or user installation is touched.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t remnacust-state-test.XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
source "$root/installer.sh"
WORK="$fixture/work"; ROOT="$fixture/root"; DEPLOY="$fixture/deploy"
mkdir -p "$WORK" "$ROOT" "$DEPLOY"
HELPER="$root/runtime.py"; STATE="$fixture/state.json"; COMPONENT=panel; LOG="$fixture/test.log"
printf '{"mainService":"api","applications":["api","worker","scheduler"],"composeFiles":[],"directory":"test"}' > "$STATE"
printf '{"services":{"api":{},"worker":{},"scheduler":{}}}' > "$fixture/compose.json"
APPS=(api worker scheduler); START_APPS=(api worker scheduler)
compose() {
    if [[ $1 == ps ]]; then printf '%s\n' "${*: -1}"
    elif [[ $1 == --profile ]]; then cat "$fixture/compose.json"
    else return 1; fi
}
docker() {
    [[ $1 == inspect ]] || return 1
    if [[ ${2:-} == --format ]]; then [[ ${*: -1} != api ]] || { printf 'true\n'; return; }; printf 'false\n'
    else printf '[{"Config":{"Image":"fixture-image"}}]\n'; fi
}
backup_panel_data() { printf 'fixture-dump\n' > "$BACKUP/database.dump"; }
backup_current >/dev/null
python3 - "$BACKUP/state.before.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['runningApplications']==['api']
PY
printf 'PASS standalone backup saves actual running services, not stale startup state\n'
STATE="$BACKUP/state.before.json"; load_restore_apps
[[ ${START_APPS[*]} == api ]]
printf 'PASS restore keeps disabled worker and scheduler stopped\n'
printf '{"applications":["api","worker"],"runningApplications":[]}' > "$STATE"
load_restore_apps
((${#START_APPS[@]}==0))
printf 'PASS an explicitly stopped installation restores without starting applications\n'
printf '{"applications":["api","worker"]}' > "$STATE"
load_restore_apps
[[ ${START_APPS[*]} == 'api worker' ]]
printf 'PASS older backups without service state retain the documented fallback\n'
printf '{"applications":["api"],"runningApplications":["database"]}' > "$STATE"
if (set -e; load_restore_apps) >/dev/null 2>&1; then exit 1; fi
printf 'PASS inconsistent service state is rejected\n'
WORK=''
