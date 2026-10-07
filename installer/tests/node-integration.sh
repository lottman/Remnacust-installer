#!/usr/bin/env bash
# Real, isolated host-network node; no live panel or profile is contacted.
set -Eeuo pipefail
installer_dir=$(cd "$(dirname "$0")/.." && pwd)
public_source=${1:?Pass public source tree}
test_image=${2:-remnacust-node:1.1.1-20261006-final-audit}
test_root=$(mktemp -d -t remnacust-node-test.XXXXXXXX)
test_project="remnacust-node-test-$$"
cleanup_test() {
    local result=$?
    if ((result)); then cat "$test_root/operation.log" 2>/dev/null || true; fi
    docker compose --project-name "$test_project" -f "$test_root/deploy/compose.json" down --volumes >/dev/null 2>&1 || true
    [[ $test_root == /tmp/remnacust-node-test.* ]] && rm -rf -- "$test_root"
}
trap cleanup_test EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$test_root/ca.key" -out "$test_root/ca.pem" -days 1 -subj /CN=test-ca >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$test_root/node.key" -out "$test_root/node.csr" -subj /CN=test-node >/dev/null 2>&1
openssl x509 -req -in "$test_root/node.csr" -CA "$test_root/ca.pem" -CAkey "$test_root/ca.key" -CAcreateserial -out "$test_root/node.pem" -days 1 >/dev/null 2>&1
openssl pkey -in "$test_root/ca.key" -pubout -out "$test_root/jwt.pub" >/dev/null 2>&1
export REMNACUST_NODE_SECRET
REMNACUST_NODE_SECRET=$(python3 - "$test_root" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m={'caCertPem':'ca.pem','jwtPublicKey':'jwt.pub','nodeCertPem':'node.pem','nodeKeyPem':'node.key'}
print(base64.b64encode(json.dumps({k:(p/v).read_text() for k,v in m.items()}).encode()).decode())
PY
)
source "$installer_dir/installer.sh"
ROOT="$test_root/root"; WORK="$test_root/work"; mkdir -p "$WORK" "$ROOT/registry"
LOG="$test_root/operation.log"; SOURCE=$public_source; HELPER="$installer_dir/runtime.py"
COMPONENT=node; ACTION=install-node; PORT=43874; DIRECTORY="$test_root/deploy"; PROJECT=$test_project
IMAGE=$test_image; YES=true; VERSION=1.1.1
prepare_host() { docker info >/dev/null; }
release_source() { TAG=v1.1.1; SOURCE=$public_source; HELPER="$installer_dir/runtime.py"; IMAGE=$test_image; }
build_image() { docker image inspect "$IMAGE" >/dev/null; }
install_cli() { :; }
deploy
old_id=$(compose ps --quiet remnanode)
ACTION=upgrade-node; CONTAINER=$old_id; DIRECTORY=''; CHANGED=false
deploy
[[ $(docker inspect --format '{{.Config.Image}}' "$(compose ps --quiet remnanode)") == "$test_image" ]]
printf 'PASS fresh node certificate validation, API readiness and complete upgrade with preserved key/mounts/port\n'
