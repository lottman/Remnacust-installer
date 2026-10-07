#!/usr/bin/env bash
# Offline regression tests. No daemon, network, host installation or credentials.
set -Eeuo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/archive/panel/frontend" "$fixture/archive/panel/backend" \
    "$fixture/archive/node/docker" "$fixture/archive/xray/core"
export FIXTURE=$fixture
mkdir -p "$fixture/archive/installer" "$fixture/archive/subscription-page/frontend" "$fixture/archive/subscription-page/backend"
cp "$project/installer.sh" "$project/runtime.py" "$project/database.cjs" "$project/marzban.py" "$fixture/archive/installer/"
touch "$fixture/archive/panel/backend/.env.sample"
touch "$fixture/archive/panel/Dockerfile" "$fixture/archive/node/docker/Dockerfile" "$fixture/archive/xray/core/core.go"
printf '1.1.1\n' > "$fixture/archive/VERSION"
printf 'package core\nvar (Version_x byte = 1; Version_y byte = 1; Version_z byte = 1)\n' > "$fixture/archive/xray/core/core.go"
for path in panel/frontend panel/backend node subscription-page/frontend subscription-page/backend; do printf '{"version":"1.1.1"}' > "$fixture/archive/$path/package.json"; done
tar -czf "$fixture/remnacust-source-v1.1.1.tar.gz" -C "$fixture/archive" .
(cd "$fixture" && sha256sum remnacust-source-v1.1.1.tar.gz > SHA256SUMS)
python3 - "$fixture" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);tag='v1.1.1';base='https://github.com/lottman/Remnacust-installer/releases/download/'+tag+'/'
release=dict(tag_name=tag,draft=False,prerelease=False,assets=[])
for name in ['remnacust-source-v1.1.1.tar.gz','SHA256SUMS']:
    release['assets'].append(dict(name=name,state='uploaded',browser_download_url=base+name,
        digest='sha256:'+hashlib.sha256((root/name).read_bytes()).hexdigest()))
(root/'release.json').write_text(json.dumps(release))
PY
cp "$fixture/release.json" "$fixture/good-release.json"
cp "$fixture/SHA256SUMS" "$fixture/good-sums"
cat > "$fixture/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
url='';out=''
while (($#)); do
    case "$1" in -o) out=$2;shift;; https://*) url=$1;; esac
    shift
done
printf '%s\n' "$url" >> "$FIXTURE/requests"
[[ ${MOCK_FAIL:-false} != true ]] || exit 22
case "$url" in
    https://api.github.com/repos/lottman/Remnacust-installer/releases/latest|https://api.github.com/repos/lottman/Remnacust-installer/releases/tags/v1.1.1) cp "$FIXTURE/release.json" "$out";;
    https://api.github.com/repos/lottman/Remnacust-installer/releases/tags/v1.1.2) cp "$FIXTURE/release-v1.1.2.json" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.2/SHA256SUMS) cp "$FIXTURE/SHA256SUMS-v1.1.2" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.2/remnacust-source-v1.1.2.tar.gz) cp "$FIXTURE/remnacust-source-v1.1.2.tar.gz" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.1/SHA256SUMS) cp "$FIXTURE/SHA256SUMS" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.1/remnacust-source-v1.1.1.tar.gz) cp "$FIXTURE/remnacust-source-v1.1.1.tar.gz" "$out";;
    *) exit 22;;
esac
MOCK
chmod +x "$fixture/bin/curl"
export PATH="$fixture/bin:$PATH"
export REMNACUST_REPOSITORY=lottman/Remnacust-installer
pass() { printf 'PASS %s\n' "$1"; }
reject() {
    local description=$1;shift
    if "$@" > "$fixture/result" 2>&1; then cat "$fixture/result"; printf 'FAIL %s\n' "$description";exit 1;fi
    pass "$description"
}
bash "$project/installer.sh" --check-release </dev/null > "$fixture/result"
grep -q '/releases/latest' "$fixture/requests";pass 'noninteractive version defaults to latest'
bash "$project/installer.sh" --check-release --version 1.1.1 > "$fixture/result"
grep -q '/releases/tags/v1.1.1' "$fixture/requests";pass 'explicit version resolves an immutable release tag'
reject 'invalid version is rejected' bash "$project/installer.sh" --check-release --version '../main'
reject 'unknown arguments are rejected' bash "$project/installer.sh" --wat
reject 'missing release does not install anything' env MOCK_FAIL=true bash "$project/installer.sh" --check-release
printf '%064d  remnacust-source-v1.1.1.tar.gz\n' 0 > "$fixture/SHA256SUMS"
reject 'corrupt source checksum is rejected' bash "$project/installer.sh" --check-release
cp "$fixture/good-sums" "$fixture/SHA256SUMS"
python3 - "$fixture/release.json" <<'PY'
import json,sys
p=sys.argv[1];r=json.load(open(p));r['assets'][0]['browser_download_url']='https://example.org/installer';json.dump(r,open(p,'w'))
PY
reject 'foreign asset URLs are rejected' bash "$project/installer.sh" --check-release
cp "$fixture/good-release.json" "$fixture/release.json"
python3 - "$fixture/release.json" <<'PY'
import json,sys
p=sys.argv[1];r=json.load(open(p));r['prerelease']=True;json.dump(r,open(p,'w'))
PY
reject 'latest cannot silently install a prerelease' bash "$project/installer.sh" --check-release
cp "$fixture/good-release.json" "$fixture/release.json"
# Re-sign an intentionally unsafe fixture: integrity alone must not allow traversal.
cp "$fixture/remnacust-source-v1.1.1.tar.gz" "$fixture/good-source.tar.gz"
python3 - "$fixture" <<'PY'
import hashlib,io,json,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]);name='remnacust-source-v1.1.1.tar.gz'
with tarfile.open(root/name,'w:gz') as archive:
    entry=tarfile.TarInfo('../outside');entry.size=4;archive.addfile(entry,io.BytesIO(b'test'))
digest=hashlib.sha256((root/name).read_bytes()).hexdigest()
(root/'SHA256SUMS').write_text(digest+'  '+name+'\n')
p=root/'release.json';release=json.loads(p.read_text());release['assets'][0]['digest']='sha256:'+digest;p.write_text(json.dumps(release))
PY
reject 'valid checksum does not permit archive path traversal' bash "$project/installer.sh" --check-release
[[ ! -e $fixture/outside ]] || exit 1
cp "$fixture/good-source.tar.gz" "$fixture/remnacust-source-v1.1.1.tar.gz"
cp "$fixture/good-sums" "$fixture/SHA256SUMS"
cp "$fixture/good-release.json" "$fixture/release.json"

source "$project/installer.sh"
show_menu > "$fixture/menu"
for action in install-panel install-node upgrade-panel upgrade-node migrate-remnawave-panel migrate-remnawave-node migrate-marzban-panel status; do grep -q "$action" "$fixture/menu"; done
! grep -q upgrade-core "$fixture/menu"
DIRECTORY="$fixture/existing"; mkdir -p "$DIRECTORY"; touch "$DIRECTORY/.env"
show_menu > "$fixture/existing-menu"; cmp "$fixture/menu" "$fixture/existing-menu"
pass 'all commands always visible, upgrade-core removed'
(ask() { printf 0; }; command() { return 1; }; ACTION=''; main) > "$fixture/no-tools-menu"
cmp "$fixture/menu" "$fixture/no-tools-menu"
pass 'menu and exit do not need Docker or network'
reject 'upgrade-core cannot run' bash "$project/installer.sh" upgrade-core
reject 'Marzban-only flags cannot modify a normal install' bash "$project/installer.sh" install-panel --dry-run
(
 COMPONENT=panel; START_APPS=(custom-api); STATE=none
 compose() { [[ $* == 'ps --all --quiet custom-api' ]] || exit 1; printf actual-id; }
 docker() { [[ ${!#} == actual-id ]] || exit 1; printf healthy; }
 wait_ready
)
pass 'readiness uses actual service container ID'
(
 COMPONENT=panel; CHANGED=true; DB_CHANGED=true; BACKUP="$fixture/backup"; LOG="$fixture/failure.log"; APPS=(api processor scheduler)
 compose() { printf '%s\n' "$*" >> "$fixture/failure-requests"; }
 false
) >/dev/null 2>&1 || true
(
 COMPONENT=panel; CHANGED=true; DB_CHANGED=true; BACKUP="$fixture/backup"; LOG="$fixture/failure.log"; APPS=(api processor scheduler)
 compose() { printf '%s\n' "$*" >> "$fixture/failure-requests"; }
 recover
) >/dev/null 2>&1 || true
grep -qx 'stop api processor scheduler' "$fixture/failure-requests"
! grep -q postgres "$fixture/failure-requests"
pass 'failed migration stops every writer and preserves infrastructure'
(
 COMPONENT=node; CHANGED=true; DB_CHANGED=false; BACKUP="$fixture/backup"; LOG="$fixture/failure.log"; START_APPS=(node)
 load_state() { :; }; compose() { printf '%s\n' "$*" >> "$fixture/node-requests"; }
 recover
) >/dev/null 2>&1 || true
grep -qx 'up -d --no-deps --no-build --pull never node' "$fixture/node-requests"
pass 'node rollback restarts original image without pulling or rebuilding'
set +e
(
    set -e
    ACTION=install-panel; COMPONENT=panel; VERSION=1.1.1; YES=true
    ROOT="$fixture/new-root"; WORK="$fixture/new-work"; LOG="$fixture/new-install.log"
    mkdir -p "$WORK" "$ROOT/registry"
    prepare_host() { :; }; lock_operation() { :; }; build_image() { :; }
    release_source() { TAG=v1.1.1; }
    docker() { printf /tmp; }
    df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\ntest 16000000 1 15999999 1%% /tmp\n'; }
    fresh_files() { STATE="$WORK/state.json"; printf '{}' > "$STATE"; }
    helper() { :; }
    helper_file_copy() { cp "$1" "$2"; }
    install_cli() { touch "$fixture/recovery-cli-ready"; }
    step() { [[ $1 != 'Запуск установки' ]]; }
    deploy
) >/dev/null 2>&1
first_boot_status=$?
set -e
((first_boot_status != 0)) || { printf 'FAIL expected first boot failure\n'; exit 1; }
[[ -f $fixture/recovery-cli-ready && -s $fixture/new-root/registry/panel.json ]]
pass 'first boot failure retains registry and recovery CLI'
(
    WORK="$fixture/cli-work"; SOURCE="$fixture/old-source"
    mkdir -p "$WORK" "$SOURCE/installer"
    printf '#!/bin/bash\necho old-installer\n' > "$SOURCE/installer/installer.sh"
    install() {
        case "${!#}" in
            "$WORK/installer-entry.sh") command install "$@";;
            /usr/local/bin/remnacust) command install -m 0755 "${@: -2:1}" "$fixture/installed-cli";;
            /usr/local/lib/remnacust-installer*) :;;
            *) exit 1;;
        esac
    }
    ln() { :; }
    install_cli
    cmp "$project/installer.sh" "$fixture/installed-cli"
    # Calling the installed entry again must work when its destination already exists.
    source "$fixture/installed-cli"
    WORK="$fixture/cli-work"; SOURCE="$fixture/old-source"
    install_cli
    cmp "$project/installer.sh" "$fixture/installed-cli"
)
pass 'installing an older bundle preserves current CLI policy and supports self-update'
make_patch_release() {
    python3 - "$fixture" "$1" <<'PY'
import hashlib,json,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]);source=root/'archive';version=sys.argv[2]
(source/'VERSION').write_text('1.1.2\n')
(source/'component-sources.json').write_text(json.dumps({kind:{'repository':'lottman/Remnacust-'+kind,'commit':'a'*40,'version':version if kind=='node' else '1.1.1'} for kind in ['panel','node','core']}))
name='remnacust-source-v1.1.2.tar.gz'
with tarfile.open(root/name,'w:gz') as archive:archive.add(source,arcname='.')
digest=hashlib.sha256((root/name).read_bytes()).hexdigest()
(root/'SHA256SUMS-v1.1.2').write_text(digest+'  '+name+'\n')
release=dict(tag_name='v1.1.2',draft=False,prerelease=False,assets=[])
for asset,local in [(name,name),('SHA256SUMS','SHA256SUMS-v1.1.2')]:
    release['assets'].append(dict(name=asset,state='uploaded',browser_download_url='https://github.com/lottman/Remnacust-installer/releases/download/v1.1.2/'+asset,digest='sha256:'+hashlib.sha256((root/local).read_bytes()).hexdigest()))
(root/'release-v1.1.2.json').write_text(json.dumps(release))
PY
}
make_patch_release 1.1.1
bash "$project/installer.sh" --check-release --version 1.1.2 > "$fixture/result"
pass 'installer patch accepts independently pinned application versions'
make_patch_release 1.1.0
reject 'valid archive checksum cannot conceal an incorrect pinned component version' bash "$project/installer.sh" --check-release --version 1.1.2
grep -q 'Версия исходников не совпадает с закреплённым компонентом: node' "$fixture/result"
WORK=''
printf 'Installer bootstrap checks passed.\n'
