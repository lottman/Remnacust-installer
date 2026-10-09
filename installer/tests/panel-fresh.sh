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
YES=true; VERSION=latest
SUBSCRIPTION_URLS=${3:-}
COMPONENT_VERSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$public_source/panel/backend/package.json")
prepare_host() { docker info >/dev/null; }
release_source() { TAG=v$(cat "$public_source/VERSION"); SOURCE=$public_source; HELPER="$installer_dir/runtime.py"; IMAGE=$test_image; }
prepare_image() { docker image inspect "$IMAGE" >/dev/null; }
install_cli() { :; }
configure_panel_updates() { :; }
deploy
[[ -s $ROOT/registry/panel.json ]]
[[ $(stat -c %a "$DEPLOY/.env") == 600 ]]
docker inspect "$(compose ps --quiet remnawave)" > "$WORK/inspect.json"
python3 - "$WORK/inspect.json" "$ROOT/registry/panel.json" "$COMPONENT_VERSION" "$SUBSCRIPTION_URLS" <<'PY'
import json, sys
c=json.load(open(sys.argv[1]))[0]
env=dict(v.split('=',1) for v in c['Config']['Env'] if '=' in v)
assert env['HWID_ENABLED_DEFAULT']=='true'
assert len(env['APP_SECRET'])==64 and len(env['METRICS_PASS'])>=32
assert c['HostConfig']['PortBindings']['3000/tcp'][0]['HostIp']=='127.0.0.1'
state=json.load(open(sys.argv[2]))
assert state['version']==sys.argv[3] and state['component']=='panel'
assert state['subscriptionUrls']==sys.argv[4].split(',')
assert 'https://'+env['SUB_PUBLIC_DOMAIN']==state['subscriptionUrls'][0]
assert ',' not in env['SUB_PUBLIC_DOMAIN']
PY
[[ $(docker inspect --format '{{.Config.Image}}' "$(compose ps --quiet remnawave-db)") == postgres:18.4 ]]
curl --fail --silent --show-error -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 127.0.0.1' \
    http://127.0.0.1:43875/api/auth/status >/dev/null
printf 'PASS fresh panel, PostgreSQL 18, Valkey, API, HWID default, protected secrets and loopback binding\n'
docker exec -i "$(compose ps --quiet remnawave)" node <<'JS'
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
(async () => {
    const headers = {'Content-Type':'application/json', 'X-Forwarded-Proto':'https',
        'X-Forwarded-For':'127.0.0.1', 'X-Remnawave-Client-Type':'browser'};
    const register = await fetch('http://127.0.0.1:3000/api/auth/register', {method:'POST',headers,
        body:JSON.stringify({username:'fixture_admin',password:'Aa1'+crypto.randomBytes(24).toString('hex')})});
    assert.equal(register.status, 201, 'Temporary administrator registration failed');
    const token = (await register.json()).response.accessToken;
    const response = await fetch('http://127.0.0.1:3000/api/users', {method:'POST',
        headers:{...headers, Authorization:'Bearer '+token},
        body:JSON.stringify({username:'subscription_fixture',expireAt:new Date(Date.now()+86400000).toISOString()})});
    assert.equal(response.status, 201, 'Temporary user creation failed');
    const user = (await response.json()).response;
    assert.equal(user.subscriptionUrl, 'https://'+process.env.SUB_PUBLIC_DOMAIN+'/'+user.shortUuid);
    assert(!user.subscriptionUrl.includes(','));
    console.log('PASS running panel creates a valid subscription URL from the selected primary address');
})().catch(() => {console.error('FAIL fresh subscription URL API verification');process.exitCode=1;});
JS
