#!/usr/bin/env bash
set -Eeuo pipefail
installer=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t remnacust-preflight.XXXXXXXX)
trap '[[ $fixture == /tmp/remnacust-preflight.* ]] && rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/root"
export FIXTURE=$fixture REMNACUST_ROOT="$fixture/root" MOCK_DOCKER=app
cat > "$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FIXTURE/docker-calls"
[[ $MOCK_DOCKER != unavailable ]] || exit 1
case "$*" in
    *com.docker.compose.service=remnawave*)
        if [[ $MOCK_DOCKER == app ]]; then printf 'abc123|remnacust-panel|ghcr.io/lottman/remnacust-panel:1.1.2\n'; fi
        if [[ $MOCK_DOCKER == stock ]]; then printf 'def456|remnawave|remnawave/backend:3.4.4\n'; fi;;
    *com.docker.compose.project=remnacust-panel*)
        if [[ $MOCK_DOCKER == db ]]; then printf 'remnacust-panel-db-1 · /opt/previous-panel\n'; fi;;
esac
MOCK
cat > "$fixture/bin/curl" <<'MOCK'
#!/usr/bin/env bash
touch "$FIXTURE/unexpected-download"
exit 1
MOCK
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
source "$installer/installer.sh"
component_installed panel
! component_installed node
show_menu > "$fixture/menu"
grep -q uninstall-panel "$fixture/menu"
grep -q 'upgrade-panel.*Обновить панель$' "$fixture/menu"
if bash "$installer/installer.sh" install-panel > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'уже установлен' "$fixture/output"
[[ ! -f $fixture/unexpected-download && ! -d $ROOT/panel ]]
grep -q -- '--all.*com.docker.compose.service=remnawave' "$fixture/docker-calls"
printf 'PASS stopped/legacy Compose app detected before confirmation, domain and network access\n'
export MOCK_DOCKER=db
if bash "$installer/installer.sh" install-panel > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'Проект remnacust-panel уже существует' "$fixture/output"
grep -q /opt/previous-panel "$fixture/output"
[[ ! -f $fixture/unexpected-download ]]
printf 'PASS surviving infrastructure collision includes the old working directory before prompts\n'
export MOCK_DOCKER=unavailable
if bash "$installer/installer.sh" install-panel --yes > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'Docker daemon недоступен' "$fixture/output"
printf 'PASS inaccessible daemon cannot masquerade as an empty server\n'
export MOCK_DOCKER=stock
! component_installed panel
printf 'PASS unrelated upstream Remnawave project is not mistaken for this installation\n'
mkdir -p "$ROOT/registry" "$ROOT/panel"
printf 'not-json' > "$ROOT/registry/panel.json"
touch "$ROOT/panel/compose.yml"
component_installed panel
printf 'PASS malformed registry still falls back to an existing Compose directory\n'
if bash "$installer/installer.sh" upgrade-panel --email test@example.com > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'обновление сохраняет' "$fixture/output"
printf 'PASS certificate creation options cannot change a proxy during upgrades\n'
WORK=''
