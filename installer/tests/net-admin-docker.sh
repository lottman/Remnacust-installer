#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d -t remnacust-netadmin.XXXXXXXX)
project="remnacust-netadmin-$$"
cleanup_test() {
    docker compose --project-name "$project" --file "$fixture/compose.json" down --volumes >/dev/null 2>&1 || true
    rm -rf -- "$fixture"
}
trap cleanup_test EXIT
: > "$fixture/.env"
for enabled in false true; do
    options=()
    if [[ $enabled == true ]]; then options=(--panel-net-admin); fi
    python3 "$root/installer/runtime.py" fresh --component panel --directory "$fixture" \
        --project "$project" --image alpine:3.22 --proxy existing --domain panel.example.com \
        --target "$fixture/compose.json" --state "$fixture/state.json" "${options[@]}"
    actual=$(docker compose --project-name "$project" --file "$fixture/compose.json" run --rm --no-deps \
        --entrypoint sh remnawave -c 'cap=$(awk "/^CapEff:/ {print \$2}" /proc/self/status); if [ "$((0x$cap & 4096))" -ne 0 ]; then echo true; else echo false; fi')
    [[ $actual == "$enabled" ]]
    echo "PASS panel NET_ADMIN=$enabled is applied by Docker Compose"
done
for enabled in false true; do
    options=()
    if [[ $enabled == false ]]; then options=(--node-no-net-admin); fi
    python3 "$root/installer/runtime.py" fresh --component node --directory "$fixture" \
        --project "$project" --image alpine:3.22 \
        --target "$fixture/compose.json" --state "$fixture/state.json" "${options[@]}"
    actual=$(docker compose --project-name "$project" --file "$fixture/compose.json" run --rm --no-deps \
        --entrypoint sh remnanode -c 'cap=$(awk "/^CapEff:/ {print \$2}" /proc/self/status); if [ "$((0x$cap & 4096))" -ne 0 ]; then echo true; else echo false; fi')
    [[ $actual == "$enabled" ]]
    echo "PASS node NET_ADMIN=$enabled is applied by Docker Compose"
done
