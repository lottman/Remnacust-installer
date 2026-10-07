#!/usr/bin/env bash
# A local TLS fixture: no public domain or ACME account is used.
set -Eeuo pipefail
installer=$(cd "$(dirname "$0")/.." && pwd)
source_tree=${1:?Pass the public panel source tree}
fixture=$(mktemp -d -t remnacust-panel-tls.XXXXXXXX)
fixture_project="remnacust-panel-tls-$$"
cleanup_test() {
 local status=$?
 if ((status)); then cat "$fixture/log" 2>/dev/null || true; fi
 docker compose --project-name "$fixture_project" -f "$fixture/deploy/compose.json" down --volumes >/dev/null 2>&1 || true
 [[ $fixture == /tmp/remnacust-panel-tls.* ]] && rm -rf -- "$fixture"
}
trap cleanup_test EXIT
source "$installer/installer.sh"
ROOT="$fixture/root"; WORK="$fixture/work"; LOG="$fixture/log"; HELPER="$installer/runtime.py"; SOURCE=$source_tree
mkdir -p "$WORK" "$ROOT/registry"
COMPONENT=panel; ACTION=install-panel; DIRECTORY="$fixture/deploy"; DOMAIN=panel.example.com; NODE_DOMAIN=''; PROJECT=$fixture_project
IMAGE=nginx:1.28-alpine; PROXY=caddy; TLS_METHOD=existing; PORT=43874
CERT_FILE="$fixture/cert"; KEY_FILE="$fixture/key"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3 -subj /CN=panel.example.com -addext subjectAltName=DNS:panel.example.com >/dev/null 2>&1
certificate_preflight
# This fixture publishes TLS on 43876, so host listeners on 80/443 are irrelevant.
# Keep the production port check intact and bypass only those two unused bindings.
original_port_check=$(declare -f port_free)
eval "${original_port_check/port_free/fixture_port_free}"
port_free() { [[ $1 == 80 || $1 == 443 ]] || fixture_port_free "$1"; }
fresh_files
tls_helper copy --domain "$DOMAIN" --certificate "$CERT_FILE" --key "$KEY_FILE" --directory "$DEPLOY"
tls_helper record --state "$STATE" --method existing --certificate "$CERT_FILE" --key "$KEY_FILE"
python3 - "$DEPLOY/compose.json" <<'PY'
import json,sys
p=sys.argv[1];c=json.load(open(p));c['services']={'caddy':c['services']['caddy'],'remnawave':{'image':'python:3.12-alpine','command':['python','-m','http.server','3000']}}
c['services']['caddy']['ports']=['127.0.0.1:43876:443'];json.dump(c,open(p,'w'))
PY
compose up -d >/dev/null
for i in {1..30}; do
 if curl --fail --silent --noproxy '*' --cacert "$CERT_FILE" --resolve "$DOMAIN:43876:127.0.0.1" "https://$DOMAIN:43876/" > "$WORK/page"; then break; fi
 sleep 1
done
[[ -s $WORK/page ]]
app_id=$(compose ps --quiet remnawave); proxy_id=$(compose ps --quiet caddy)
started=$(docker inspect --format '{{.State.StartedAt}}' "$proxy_id")
fingerprint() { openssl s_client -connect 127.0.0.1:43876 -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256; }
before=$(fingerprint)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3 -subj /CN=panel.example.com -addext subjectAltName=DNS:panel.example.com >/dev/null 2>&1
renew_certificate
after=$(fingerprint)
[[ $before != "$after" && $(compose ps --quiet remnawave) == "$app_id" && $(compose ps --quiet caddy) == "$proxy_id" ]]
[[ $(docker inspect --format '{{.State.StartedAt}}' "$proxy_id") == "$started" ]]
curl --fail --silent --noproxy '*' --cacert "$CERT_FILE" --resolve "$DOMAIN:43876:127.0.0.1" "https://$DOMAIN:43876/" >/dev/null
printf 'PASS actual HTTPS and renewed certificate without restarting Caddy or application\n'
