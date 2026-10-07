#!/usr/bin/env bash
# Disposable fresh installation with the real panel, PostgreSQL and Valkey.
set -Eeuo pipefail
installer_dir=$(cd "$(dirname "$0")/.." && pwd)
public_source=${1:?Pass a public source tree}
test_image=${2:-remnacust-panel:1.1.1-20261006-public-key}
test_root=$(mktemp -d -t remnacust-fresh-test.XXXXXXXX)
test_project="remnacust-fresh-test-$$"
cleanup_test() {
    local result=$?
    if ((result)); then
        cat "$test_root/operation.log" 2>/dev/null || true
        docker compose --project-name "$test_project" -f "$test_root/deploy/compose.json" logs --tail 50 2>&1 || true
    fi
    docker compose --project-name "$test_project" -f "$test_root/deploy/compose.json" down --volumes >/dev/null 2>&1 || true
    [[ $test_root == /tmp/remnacust-fresh-test.* ]] && rm -rf -- "$test_root"
}
trap cleanup_test EXIT
source "$installer_dir/installer.sh"
ROOT="$test_root/root"; WORK="$test_root/work"; mkdir -p "$WORK" "$ROOT/registry"
LOG="$test_root/operation.log"; HELPER="$installer_dir/runtime.py"
COMPONENT=panel; ACTION=install-panel; PROXY=existing; DOMAIN=panel.example.com; PORT=43875
DIRECTORY="$test_root/deploy"; PROJECT=$test_project
YES=true; VERSION=1.1.1
prepare_host() { docker info >/dev/null; }
release_source() { TAG=v1.1.1; SOURCE=$public_source; HELPER="$installer_dir/runtime.py"; IMAGE=$test_image; }
prepare_image() { docker image inspect "$IMAGE" >/dev/null; }
install_cli() { :; }
deploy
[[ -s $ROOT/registry/panel.json ]]
[[ $(stat -c %a "$DEPLOY/.env") == 600 ]]
docker inspect "$(compose ps --quiet remnawave)" > "$WORK/inspect.json"
python3 - "$WORK/inspect.json" "$ROOT/registry/panel.json" <<'PY'
import json, sys
c=json.load(open(sys.argv[1]))[0]
env=dict(v.split('=',1) for v in c['Config']['Env'] if '=' in v)
assert env['HWID_ENABLED_DEFAULT']=='true'
assert len(env['APP_SECRET'])==64 and len(env['METRICS_PASS'])>=32
assert c['HostConfig']['PortBindings']['3000/tcp'][0]['HostIp']=='127.0.0.1'
state=json.load(open(sys.argv[2]))
assert state['version']=='1.1.1' and state['component']=='panel'
PY
[[ $(docker inspect --format '{{.Config.Image}}' "$(compose ps --quiet remnawave-db)") == postgres:18.4 ]]
curl --fail --silent --show-error -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 127.0.0.1' \
    http://127.0.0.1:43875/api/auth/status >/dev/null
printf 'PASS fresh panel, PostgreSQL 18, Valkey, API, HWID default, protected secrets and loopback binding\n'
