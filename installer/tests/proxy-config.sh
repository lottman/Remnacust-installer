#!/usr/bin/env bash
# Validate generated proxy configurations without contacting ACME or changing DNS.
set -Eeuo pipefail
installer_dir=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d -t remnacust-proxy-test.XXXXXXXX)
trap '[[ $test_root == /tmp/remnacust-proxy-test.* ]] && rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/certs"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$test_root/certs/privkey.pem" -out "$test_root/certs/fullchain.pem" -days 3 -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com >/dev/null 2>&1
python3 "$installer_dir/runtime.py" node-proxy --directory "$test_root" --domain node.example.com
docker run --rm --entrypoint nginx \
    -v "$test_root/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$test_root/certs:/var/lib/remnacust/tls:ro" \
    -v "$test_root/run:/var/lib/remnacust/run" \
    -v "$test_root/www:/usr/share/nginx/html:ro" nginx:1.28-alpine -t
python3 "$installer_dir/tls.py" caddy --directory "$test_root" --domain panel.example.com --email admin@example.com --method auto
docker run --rm -v "$test_root/Caddyfile:/tmp/Caddyfile:ro" caddy:2-alpine caddy validate --config /tmp/Caddyfile --adapter caddyfile
python3 "$installer_dir/tls.py" caddy --directory "$test_root" --domain node.example.com --method existing
docker run --rm -v "$test_root/Caddyfile:/tmp/Caddyfile:ro" -v "$test_root/certs:/var/lib/remnacust/tls:ro" caddy:2-alpine caddy validate --config /tmp/Caddyfile --adapter caddyfile
printf 'PASS real Nginx TLS/HTTP2/Unix/XHTTP and Caddy configuration validation\n'
