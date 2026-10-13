#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
case_id="remnacust-nettest-$$"
private="$case_id-private"
proxy="$case_id-proxy"
database="$case_id-db"
panel="$case_id-panel"
work=$(mktemp -d -t remnacust-nettest.XXXXXXXX)
cleanup_test() {
    docker rm -f "$panel" "$database" >/dev/null 2>&1 || true
    docker network rm "$private" "$proxy" >/dev/null 2>&1 || true
    rm -rf -- "$work"
}
trap cleanup_test EXIT

docker network create "$private" >/dev/null
docker network create "$proxy" >/dev/null
docker run -d --rm --name "$database" --network "$private" --network-alias remnawave-db alpine:3.22 sleep 120 >/dev/null
docker run -d --rm --name "$panel" --network "$proxy" \
    --env 'DATABASE_URL=postgresql://user:pass@remnawave-db:5432/db' \
    --env 'APP_SECRET=sample' alpine:3.22 sleep 120 >/dev/null
docker network connect "$private" "$panel"
docker inspect "$panel" > "$work/container.before.json"

source "$root/installer/installer.sh"
WORK=$work
HELPER="$root/installer/runtime.py"
database_environment
[[ $(cat "$work/database.network") == "$private" ]]
if REMNACUST_DATABASE_NETWORK="$proxy" database_environment > /dev/null 2>&1; then
    echo 'FAIL: the override selected a network without the database' >&2
    exit 1
fi
echo 'PASS multi-network database selection follows the live database alias'
