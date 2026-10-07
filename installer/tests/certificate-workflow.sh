#!/usr/bin/env bash
set -Eeuo pipefail
installer=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t remnacust-certificate-workflow.XXXXXXXX)
trap '[[ $fixture == /tmp/remnacust-certificate-workflow.* ]] && rm -rf -- "$fixture"' EXIT
source "$installer/installer.sh"
ROOT="$fixture/root"; WORK="$fixture/work"; LOG="$fixture/log"; HELPER="$installer/runtime.py"
mkdir -p "$WORK" "$ROOT/tools/certbot/bin"
export FIXTURE=$fixture
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$fixture/key" -out "$fixture/cert" -days 3 -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com >/dev/null 2>&1
cat > "$ROOT/tools/certbot/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ $1 != plugins ]] || { printf 'dns-gcore\n'; exit; }
printf '%s\n' "$*" >> "$FIXTURE/certbot-calls"
config='';domain=''
while (($#)); do
 case "$1" in --config-dir) config=$2;shift;;--cert-name) domain=$2;shift;;esac
 shift
done
mkdir -p "$config/live/$domain"
cp "$FIXTURE/cert" "$config/live/$domain/fullchain.pem"
cp "$FIXTURE/key" "$config/live/$domain/privkey.pem"
MOCK
chmod +x "$ROOT/tools/certbot/bin/certbot"
port_free() { printf '%s\n' "$1" >> "$fixture/ports"; }
for method in http cloudflare gcore; do
 COMPONENT=node; DOMAIN=''; NODE_DOMAIN=node.example.com; TLS_METHOD=$method; EMAIL=admin@example.com; PROJECT="fixture-$method"
 DNS_CREDENTIALS=''
 if [[ $method != http ]]; then
  DNS_CREDENTIALS="$fixture/$method.ini"
  if [[ $method == cloudflare ]]; then printf 'dns_cloudflare_api_token = fixture-token\n' > "$DNS_CREDENTIALS"
  else printf 'dns_gcore_apitoken = fixture-token\n' > "$DNS_CREDENTIALS"; fi
  chmod 600 "$DNS_CREDENTIALS"
 fi
 obtain_certificate
 [[ $ACME_ROOT == "$ROOT/acme/$PROJECT" && -f $CERT_FILE && -f $KEY_FILE ]]
 grep -q -- "--config-dir $ACME_ROOT/config.*--email admin@example.com" "$fixture/certbot-calls"
 if [[ $method != http ]]; then
  grep -q -- "--authenticator dns-$method --dns-$method-credentials $ACME_ROOT/dns.ini" "$fixture/certbot-calls"
  [[ $(stat -c %a "$ACME_ROOT/dns.ini") == 600 ]]
 fi
 [[ ! -d $ROOT/node && ! -f $ROOT/registry/node.json ]]
done
printf 'PASS HTTP/Cloudflare/Gcore use separate ACME directories and issue before application creation\n'
CERT_FILE="$fixture/cert"; KEY_FILE="$fixture/key"; DEPLOY="$fixture/deploy"; mkdir -p "$DEPLOY" "$ROOT/registry"
STATE="$WORK/state.json"; printf '{"component":"panel","panelDomain":"node.example.com","nodeDomain":""}' > "$STATE"
COMPONENT=panel; DOMAIN=node.example.com; NODE_DOMAIN=''; TLS_METHOD=existing; PROXY=caddy; EXTRAS=(caddy); APPS=(app)
helper_file_copy() { cp "$1" "$2"; }
compose() { printf '%s\n' "$*" >> "$fixture/compose-calls"; }
configure_certificate
RENEWED_LINEAGE="$fixture/unrelated"
renew_certificate
! grep -q 'reload' "$fixture/compose-calls"
unset RENEWED_LINEAGE
renew_certificate
grep -qx 'exec -T caddy caddy reload --force --config /etc/caddy/Caddyfile --adapter caddyfile' "$fixture/compose-calls"
! grep -qE 'restart|stop|down' "$fixture/compose-calls"
printf 'PASS panel renewal ignores another lineage and reloads only its Caddy\n'
WORK=''
