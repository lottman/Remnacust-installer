#!/usr/bin/env bash
# Start all application roles against an isolated, empty database before publishing.
set -Eeuo pipefail
image=${1:?Pass panel image}
version=${2:?Pass expected version}
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
containers+=("$(docker run -d --name "$name-db" --network "$network" --network-alias audit-db -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17-alpine)")
containers+=("$(docker run -d --name "$name-redis" --network "$network" --network-alias audit-redis valkey/valkey:9-alpine)")
for attempt in $(seq 1 30);do docker exec "$name-db" pg_isready -U postgres >/dev/null 2>&1 && break;sleep 1;done
secret=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
containers+=("$(docker run -d --name "$name" --network "$network" \
    -e APP_SECRET="$secret" -e DATABASE_URL=postgresql://postgres@audit-db:5432/postgres \
    -e REDIS_HOST=audit-redis -e REDIS_PORT=6379 -e API_INSTANCES=1 -e WORKER_INSTANCES=1 \
    -e APP_PORT=3000 -e METRICS_PORT=3001 -e FRONT_END_DOMAIN=panel.example.com -e SUB_PUBLIC_DOMAIN=sub.example.com \
    -e METRICS_USER=audit -e METRICS_PASS=test-only "$image")")
ready=false
for attempt in $(seq 1 90);do
    if docker exec "$name" node -e 'fetch("http://127.0.0.1:3000/api/auth/status",{headers:{"X-Forwarded-For":"127.0.0.1","X-Forwarded-Proto":"https"}}).then(r=>{if(r.status!==200)process.exitCode=1}).catch(()=>process.exitCode=1)' >/dev/null 2>&1;then ready=true;break;fi
    sleep 2
done
[[ $ready == true ]] || { echo 'Panel API did not become ready';exit 1; }
docker exec --env EXPECTED_VERSION="$version" "$name" node -e 'if(require("/opt/app/package.json").version!==process.env.EXPECTED_VERSION)process.exit(1)'
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
printf 'PASS fresh panel database and all three application roles without restarts\n'
