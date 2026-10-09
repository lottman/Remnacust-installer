#!/usr/bin/env bash
# Disposable fresh installation with the real panel, PostgreSQL and Valkey.
set -Eeuo pipefail
installer_dir=$(cd "$(dirname "$0")/.." && pwd)
public_source=${1:?Pass a public source tree}
test_image=${2:-remnacust-panel:1.1.1-20261006-public-key}
test_root=$(mktemp -d -t remnacust-fresh-test.XXXXXXXX)
test_project="remnacust-fresh-test-$$"
test_shell_pid=$BASHPID
cleanup_test() {
    local result=$?
    [[ $BASHPID == "$test_shell_pid" ]] || return 0
    if ((result)); then
        sed -E '/Пароль резервных копий:/d' "$test_root/operation.log" 2>/dev/null || true
        docker compose --project-name "$test_project" -f "$test_root/deploy/compose.json" logs --tail 50 2>&1 || true
    fi
    docker compose --profile '*' --project-name "$test_project" -f "$test_root/deploy/compose.json" down --volumes --remove-orphans >/dev/null 2>&1 || true
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
test_page_image=${4:-}
if [[ -n $test_page_image ]]; then SUBSCRIPTION_PAGE=true; SUBSCRIPTION_PAGE_SET=true; fi
COMPONENT_VERSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$public_source/panel/backend/package.json")
prepare_host() { docker info >/dev/null; }
release_source() { TAG=v$(cat "$public_source/VERSION"); SOURCE=$public_source; HELPER="$installer_dir/runtime.py"; IMAGE=$test_image; }
prepare_image() { docker image inspect "$IMAGE" >/dev/null; }
select_subscription_image() { SUBSCRIPTION_IMAGE=$test_page_image; }
prepare_subscription_image() { docker image inspect "$SUBSCRIPTION_IMAGE" >/dev/null; }
install_cli() { :; }
configure_panel_updates() { :; }
deploy > "$test_root/completion.log"
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
if [[ -n $test_page_image ]]; then
    [[ $(stat -c %a "$DEPLOY/subscription.env") == 600 ]]
    docker exec -i "$(compose ps --quiet remnawave-subscription-page)" node <<'JS'
const assert = require('node:assert/strict');
(async () => {
    const headers = {Authorization:'Bearer '+process.env.REMNAWAVE_API_TOKEN,
        'X-Forwarded-Proto':'https', 'X-Forwarded-For':'127.0.0.1', 'Content-Type':'application/json'};
    for (const path of ['/api/system/metadata', '/api/subscription-page-configs']) {
        const response = await fetch(process.env.REMNAWAVE_PANEL_URL+path, {headers});
        assert.equal(response.status, 200, 'Required read endpoint denied: '+path);
    }
    for (const [path, method] of [['/api/users','GET'], ['/api/users','POST'],
        ['/api/tokens','GET'], ['/api/system/configuration','GET']]) {
        const response = await fetch(process.env.REMNAWAVE_PANEL_URL+path, {method,headers,
            ...(method==='POST'?{body:JSON.stringify({username:'must_not_exist'})}:{})});
        assert.equal(response.status, 403, 'Service token allowed unrelated operations: '+method+' '+path);
    }
    const status = await fetch(process.env.REMNAWAVE_PANEL_URL+'/api/auth/status', {headers});
    assert.equal((await status.json()).response.isRegisterAllowed, true, 'Setup created an administrator');
    console.log('PASS page starts with a scoped token; admin, users and configuration remain protected');
})().catch(error => {console.error('FAIL subscription service token permissions: '+error.message);process.exitCode=1;});
JS
fi
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
    require('node:fs').writeFileSync('/tmp/subscription-fixture-uuid', user.shortUuid);
    console.log('PASS running panel creates a valid subscription URL from the selected primary address');
})().catch(() => {console.error('FAIL fresh subscription URL API verification');process.exitCode=1;});
JS
if [[ -n $test_page_image ]]; then
    test_user_uuid=$(docker exec "$(compose ps --quiet remnawave)" cat /tmp/subscription-fixture-uuid)
    test_caddy="${test_project}-proxy"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj /CN=panel.example.com \
        -addext 'subjectAltName=DNS:panel.example.com,DNS:sub.example.com,DNS:alias.example.com' \
        -keyout "$WORK/test.key" -out "$WORK/test.crt" >/dev/null 2>&1
    python3 "$installer_dir/tls.py" copy --domain "$DOMAIN" --subscription-urls "$SUBSCRIPTION_URLS" \
        --certificate "$WORK/test.crt" --key "$WORK/test.key" --directory "$DEPLOY"
    python3 "$installer_dir/tls.py" caddy --domain "$DOMAIN" --subscription-urls "$SUBSCRIPTION_URLS" \
        --method existing --directory "$DEPLOY"
    docker run --rm --network "${PROJECT}_default" -v "$DEPLOY/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "$DEPLOY/certs:/var/lib/remnacust/tls:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
    docker run -d --name "$test_caddy" --label "com.docker.compose.project=$PROJECT" --network "${PROJECT}_default" \
        -p 127.0.0.1:43876:443 -v "$DEPLOY/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "$DEPLOY/certs:/var/lib/remnacust/tls:ro" caddy:2-alpine >/dev/null
    cleanup_proxy() { docker rm -f "$test_caddy" >/dev/null 2>&1 || true; cleanup_test; }
    trap cleanup_proxy EXIT
    for host in sub.example.com alias.example.com; do
        for attempt in {1..30}; do
            if curl --fail --silent --show-error --noproxy '*' --cacert "$WORK/test.crt" --resolve "$host:43876:127.0.0.1" \
                -H 'Accept: text/html' -A 'Mozilla/5.0 Chrome/130.0.0.0 Safari/537.36' "https://$host:43876/$test_user_uuid" -o "$WORK/page.html"; then break; fi
            sleep 1
        done
        grep -q '<html' "$WORK/page.html"
        code=$(curl --silent --show-error --noproxy '*' --cacert "$WORK/test.crt" --resolve "$host:43876:127.0.0.1" \
            "https://$host:43876/api/auth/status" -o "$WORK/sub-admin-response" -w '%{http_code}')
        [[ $code != 200 ]] && ! grep -q 'isRegisterAllowed' "$WORK/sub-admin-response"
    done
    printf 'PASS both subscription domains serve the page through Caddy HTTPS and do not expose panel admin routes\n'
    docker inspect "$(compose ps --quiet remnawave)" > "$WORK/container.before.json"
    database_environment; backup_current >/dev/null
    python3 - "$BACKUP/env-files.json" "$DEPLOY/subscription.env" <<'PY'
import json,sys
assert sys.argv[2] in json.load(open(sys.argv[1]))
PY
    printf 'PASS subscription credentials are included in the protected panel backup\n'
    docker exec -i --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$(get subscriptionTokenUuid)" "$(compose ps --quiet remnawave)" node <<'JS'
const {PrismaClient} = require('@prisma/client'); const prisma = new PrismaClient();
prisma.apiTokens.delete({where:{uuid:process.env.REMNACUST_SUBSCRIPTION_TOKEN_UUID}})
    .finally(() => prisma.$disconnect()).catch(() => {console.error('FAIL token revocation fixture');process.exitCode=1;});
JS
    initialize_subscription_page >/dev/null
    docker exec -i "$(compose ps --quiet remnawave-subscription-page)" node <<'JS'
(async () => {
    const response = await fetch(process.env.REMNAWAVE_PANEL_URL+'/api/system/metadata', {headers:{
        Authorization:'Bearer '+process.env.REMNAWAVE_API_TOKEN, 'X-Forwarded-For':'127.0.0.1', 'X-Forwarded-Proto':'https'}});
    if (![401,403].includes(response.status)) throw new Error('Revoked token remains usable');
    console.log('PASS restarting the subscription page does not reinstate its revoked token');
})().catch(() => {console.error('FAIL service token revocation');process.exitCode=1;});
JS
fi
