#!/usr/bin/env bash
# Start all application roles against an isolated, empty database before publishing.
set -Eeuo pipefail
image=${1:?Pass panel image}
version=${2:?Pass expected version}
project_root=$(cd "$(dirname "$0")/.." && pwd)
postgres_image=${REMNACUST_TEST_POSTGRES_IMAGE:-postgres:17-alpine}
valkey_image=${REMNACUST_TEST_VALKEY_IMAGE:-valkey/valkey:9-alpine}
fixture=$(mktemp -d /tmp/remnacust-panel-runtime.XXXXXXXX)
name="remnacust-panel-runtime-${GITHUB_RUN_ID:-local}-$$"
network="$name-net"
containers=()
cleanup() {
    local result=$?
    if ((result));then docker logs "$name" --tail 160 2>/dev/null || true;fi
    for id in "${containers[@]}";do docker rm --force "$id" >/dev/null 2>&1 || true;done
    docker network rm "$network" >/dev/null 2>&1 || true
    [[ $fixture == /tmp/remnacust-panel-runtime.* ]] && rm -rf -- "$fixture"
}
trap cleanup EXIT
docker image inspect "$image" >/dev/null
docker network create "$network" >/dev/null
containers+=("$(docker run -d --name "$name-db" --network "$network" --network-alias audit-db -e POSTGRES_HOST_AUTH_METHOD=trust "$postgres_image")")
containers+=("$(docker run -d --name "$name-redis" --network "$network" --network-alias audit-redis "$valkey_image")")
for attempt in $(seq 1 30);do docker exec "$name-db" pg_isready -U postgres >/dev/null 2>&1 && break;sleep 1;done
secret=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
containers+=("$(docker run -d --name "$name" --network "$network" \
    -e APP_SECRET="$secret" -e DATABASE_URL=postgresql://postgres@audit-db:5432/postgres \
    -e HWID_ENABLED_DEFAULT=true -e XERA_PERSONAL_SUBSCRIPTIONS=true \
    -e REDIS_HOST=audit-redis -e REDIS_PORT=6379 -e API_INSTANCES=1 -e WORKER_INSTANCES=1 \
    -e APP_PORT=3000 -e METRICS_PORT=3001 -e FRONT_END_DOMAIN=panel.example.com -e SUB_PUBLIC_DOMAIN=sub.example.com \
    -e METRICS_USER=audit -e METRICS_PASS=test-only "$image")")
wait_panel_api() {
    local ready=false attempt
    for attempt in $(seq 1 90);do
        if docker exec "$name" node -e 'fetch("http://127.0.0.1:3000/api/auth/status",{headers:{"X-Forwarded-For":"127.0.0.1","X-Forwarded-Proto":"https"}}).then(r=>{if(r.status!==200)process.exitCode=1}).catch(()=>process.exitCode=1)' >/dev/null 2>&1;then ready=true;break;fi
        sleep 2
    done
    [[ $ready == true ]] || { echo 'Panel API did not become ready';return 1; }
}
wait_panel_api
docker exec --env EXPECTED_VERSION="$version" "$name" node -e 'if(require("/opt/app/package.json").version!==process.env.EXPECTED_VERSION)process.exit(1)'
check_roles() {
for round in 1 2;do
    sleep 5
    docker exec "$name" pm2 jlist > "$fixture/processes.json"
    python3 - "$fixture/processes.json" <<'PY'
import json,sys
records=json.load(open(sys.argv[1]))
expected={'remnawave-api','remnawave-jobs','remnawave-scheduler'}
assert len(records)==3 and {r['name'] for r in records}==expected,'Application roles are missing'
assert all(r['pm2_env']['status']=='online' and r['pm2_env']['restart_time']==0 for r in records),'An application role failed or restarted'
PY
done
}
check_roles
printf 'PASS fresh panel database and all three application roles without restarts\n'
docker exec -i "$name" node < "$project_root/scripts/check-panel-hwid.cjs"

# Reproduce the historical comment-only checksum conflict in this disposable DB.
# The installer preflight must accept the known source variants without changing
# their recorded checksum, while still refusing a genuinely modified migration.
database_check() {
    docker run --rm -i --network "$network" -e APP_SECRET="$secret" \
        -e DATABASE_URL=postgresql://postgres@audit-db:5432/postgres \
        --entrypoint node "$image" - "$@" < "$project_root/installer/database.cjs"
}
migration=20260911203000_era_always_available_hosts
docker stop "$name" >/dev/null
docker exec -i "$name-db" psql -U postgres -v ON_ERROR_STOP=1 > /dev/null <<'SQL'
BEGIN;
INSERT INTO users (short_uuid, username, status, expire_at, trojan_password, vless_uuid, ss_password)
VALUES ('migration-audit', 'migration_fixture', 'DISABLED', '2099-01-01',
        'fixture-trojan-password', 'fbdcc812-8617-4f96-9a34-274495d61a13', 'fixture-shadowsocks-password');
INSERT INTO user_traffic (id) SELECT id FROM users WHERE username='migration_fixture';
INSERT INTO admin (username, password_hash, role) VALUES ('migration_admin', 'fixture-password-hash', 'ADMIN');
COMMIT;
SQL
database_check preflight
database_check snapshot > "$fixture/fingerprints.json"
python3 - "$fixture/fingerprints.json" <<'PY'
import json,sys
snapshot=json.load(open(sys.argv[1]))
assert len(snapshot['users']['hashes']) == 1 and len(snapshot['admin']['hashes']) == 1
assert snapshot['config_profiles']['hashes'] and snapshot['remnawave_settings']['hashes']
PY
for checksum in 4cd72fdfe7de50e07a5d9e6cca1282c8268fca6ba79748c0bf21530e973cd5d7 cfa557c6bb9fe4dfc992da3d78111f17a19d61df307352f8335721188f2a2aa5;do
    docker exec "$name-db" psql -U postgres -v ON_ERROR_STOP=1 -c "UPDATE _prisma_migrations SET checksum='$checksum' WHERE migration_name='$migration'" >/dev/null
    database_check preflight
    [[ $(docker exec "$name-db" psql -U postgres -Atc "SELECT checksum FROM _prisma_migrations WHERE migration_name='$migration'") == "$checksum" ]]
done
docker exec "$name-db" psql -U postgres -v ON_ERROR_STOP=1 -c "UPDATE _prisma_migrations SET checksum=repeat('f',64) WHERE migration_name='$migration'" >/dev/null
if database_check preflight > "$fixture/rejection.txt" 2>&1;then
    echo 'Modified migration was incorrectly accepted';exit 1
fi
grep -q 'unknown or modified migration' "$fixture/rejection.txt"
docker exec "$name-db" psql -U postgres -v ON_ERROR_STOP=1 -c "UPDATE _prisma_migrations SET checksum='$checksum' WHERE migration_name='$migration'" >/dev/null
docker start "$name" >/dev/null
wait_panel_api
check_roles
[[ $(docker exec "$name-db" psql -U postgres -Atc "SELECT checksum FROM _prisma_migrations WHERE migration_name='$migration'") == "$checksum" ]]
docker run --rm -i --network "$network" -e APP_SECRET="$secret" \
    -e DATABASE_URL=postgresql://postgres@audit-db:5432/postgres \
    --mount "type=bind,src=$project_root/installer/database.cjs,dst=/tmp/database-check.cjs,readonly" \
    --entrypoint node "$image" /tmp/database-check.cjs verify < "$fixture/fingerprints.json"
printf 'PASS historical migration LF/CRLF checksums, tamper rejection and panel restart with protected data preserved\n'
