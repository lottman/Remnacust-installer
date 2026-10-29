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
    https://api.github.com/repos/lottman/Remnacust-installer/releases/latest\?remnacust_check=*|https://api.github.com/repos/lottman/Remnacust-installer/releases/tags/v1.1.1) cp "$FIXTURE/release.json" "$out";;
    https://api.github.com/repos/lottman/Remnacust-installer/releases/tags/v*) cp "$FIXTURE/release-${url##*/}.json" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.2/SHA256SUMS) cp "$FIXTURE/SHA256SUMS-v1.1.2" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.2/remnacust-source-v1.1.2.tar.gz) cp "$FIXTURE/remnacust-source-v1.1.2.tar.gz" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.1/SHA256SUMS) cp "$FIXTURE/SHA256SUMS" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v1.1.1/remnacust-source-v1.1.1.tar.gz) cp "$FIXTURE/remnacust-source-v1.1.1.tar.gz" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v*/SHA256SUMS) tag=${url%/*}; cp "$FIXTURE/SHA256SUMS-${tag##*/}" "$out";;
    https://github.com/lottman/Remnacust-installer/releases/download/v*/remnacust-source-v*.tar.gz) cp "$FIXTURE/${url##*/}" "$out";;
    *) exit 22;;
esac
MOCK
cat > "$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env bash
# Bootstrap checks must not depend on containers running on the test host.
exit 0
MOCK
chmod +x "$fixture/bin/curl" "$fixture/bin/docker"
export PATH="$fixture/bin:$PATH"
export REMNACUST_REPOSITORY=lottman/Remnacust-installer
export REMNACUST_ROOT="$fixture/root"
pass() { printf 'PASS %s\n' "$1"; }
reject() {
    local description=$1;shift
    if "$@" > "$fixture/result" 2>&1; then cat "$fixture/result"; printf 'FAIL %s\n' "$description";exit 1;fi
    pass "$description"
}
bash "$project/installer.sh" --check-release </dev/null > "$fixture/result"
grep -q '/releases/latest' "$fixture/requests";pass 'noninteractive version defaults to latest'
grep -Eq '/releases/latest\?remnacust_check=[a-f0-9]{32}$' "$fixture/requests";pass 'latest metadata requests bypass shared HTTP cache'
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
for action in install-panel install-node upgrade-panel upgrade-node uninstall-panel uninstall-node migrate-remnawave-panel migrate-remnawave-node migrate-marzban-panel status; do grep -q "$action" "$fixture/menu"; done
! grep -q upgrade-core "$fixture/menu"
DIRECTORY="$fixture/existing"; mkdir -p "$DIRECTORY"; touch "$DIRECTORY/.env"
show_menu > "$fixture/existing-menu"
cmp <(grep -E '^[[:space:]]*[0-9]+[[:space:]]' "$fixture/menu") <(grep -E '^[[:space:]]*[0-9]+[[:space:]]' "$fixture/existing-menu")
pass 'all commands always visible, upgrade-core removed'
(component_installed() { return 0; }; show_menu) > "$fixture/installed-menu"
for action in install-panel install-node upgrade-panel upgrade-node uninstall-panel uninstall-node migrate-remnawave-panel migrate-remnawave-node migrate-marzban-panel; do grep -q "$action" "$fixture/installed-menu"; done
grep -Eq '^[[:space:]]*1[[:space:]]+.*install-panel' "$fixture/installed-menu"
grep -Eq '^[[:space:]]*14[[:space:]]+.*uninstall-panel' "$fixture/installed-menu"
grep -q 'Обновить: пункт 4; удалить: пункт 14' "$fixture/installed-menu"
grep -q 'Обновить: пункт 5; удалить: пункт 15' "$fixture/installed-menu"
diff -u <(printf '%s\n' {1..15} 0) <(awk '/^[[:space:]]*[0-9]+[[:space:]]/ {print $1}' "$fixture/menu")
pass 'installed components keep installation and deletion commands visible with stable numbers'
(ask() { printf 0; }; command() { return 1; }; ACTION=''; main) > "$fixture/no-tools-menu"
cmp <(grep -E '^[[:space:]]*[0-9]+[[:space:]]' "$fixture/menu") <(grep -E '^[[:space:]]*[0-9]+[[:space:]]' "$fixture/no-tools-menu")
pass 'menu and exit do not need Docker or network'

menu_actions=(install-panel install-node install-subscription-page upgrade-panel upgrade-node \
    upgrade-subscription-page migrate-remnawave-panel migrate-remnawave-node migrate-marzban-panel \
    --check-release status manage-subscription-page logs uninstall-panel uninstall-node)
for number in {1..15}; do
    (
        ask_menu_choice() { printf '%s' "$number"; }
        service_menu() { ACTION=logs; COMPONENT=node; }
        management_menu() { ACTION=manage-subscription-page; COMPONENT=subscription-page; }
        bash() { printf '%s\n' "${@:2}" > "$fixture/selected-action"; printf 'done\n' >&3; }
        interactive_menu > "$fixture/selection-menu"
    )
    [[ $(head -n 1 "$fixture/selected-action") == "${menu_actions[number-1]}" ]]
    if [[ $number == 13 ]]; then
        grep -qx -- '--component' "$fixture/selected-action"
        grep -qx node "$fixture/selected-action"
    fi
done
pass 'every displayed menu number dispatches its action without running installation'
for component in '' panel node subscription-page; do
    (
        ACTION=''; COMPONENT=''
        options=(); [[ -z $component ]] || options=(--component "$component")
        parse_args cleanup-backups "${options[@]}"
        installed_helper() { HELPER_ROOT="$project"; }
        lock_operation() { :; }
        python3() { printf '%s\n' "$@" > "$fixture/cleanup-arguments"; }
        cleanup_backups_action
        grep -qx -- '--cleanup-backups' "$fixture/cleanup-arguments"
        if [[ -n $component ]]; then grep -qx "$component" "$fixture/cleanup-arguments"; fi
    )
done
pass 'cleanup command supports all components without deployment or lifecycle calls'
(
    ACTION=''; COMPONENT=''
    parse_args change-domain --component node --domain node.example.test --email admin@example.test --tls-method http
    [[ $ACTION == change-domain && $TLS_METHOD == http && $EMAIL == admin@example.test ]]
)
(
    ACTION=''; COMPONENT=''
    parse_args change-domain --component subscription-page --domain sub.example.test --tls-method existing --cert-file /cert.pem --key-file /key.pem
    [[ $CERT_FILE == /cert.pem && $KEY_FILE == /key.pem ]]
)
pass 'domain change accepts certificate arguments without allowing them during upgrades'
reject 'upgrade does not replace existing TLS settings' bash "$project/installer.sh" upgrade-node --email admin@example.test
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
 COMPONENT=node; CHANGED=true; DB_CHANGED=false; BACKUP="$fixture/backup"; LOG="$fixture/failure.log"; APPS=(node); START_APPS=(node)
 verify_node_image_policy() { printf 'probe\n' >> "$fixture/node-requests"; }
 wait_ready() { :; }; helper_file_copy() { :; }
 load_state() { :; }; compose() { printf '%s\n' "$*" >> "$fixture/node-requests"; }
 helper() { printf '%s\n' "$*" >> "$fixture/node-requests"; }
 recover
) >/dev/null 2>&1 || true
grep -qx 'up -d --no-deps --no-build --pull never node' "$fixture/node-requests"
[[ $(sed -n '1p' "$fixture/node-requests") == "stop node" ]]
[[ $(sed -n '2p' "$fixture/node-requests") == "restore-compose --directory $fixture/backup" ]]
[[ $(sed -n '3p' "$fixture/node-requests") == probe ]]
pass 'node rollback restarts original image without pulling or rebuilding'
(
 COMPONENT=node; CHANGED=true; DB_CHANGED=false; BACKUP="$fixture/backup"; LOG="$fixture/failure.log"; START_APPS=(node)
 helper() { return 1; }; compose() { if [[ $1 == up ]]; then touch "$fixture/unsafe-restart"; fi; }
 recover
) >/dev/null 2>&1 || true
[[ ! -f $fixture/unsafe-restart ]]
pass 'failed Compose restoration does not start applications against an unknown configuration'
set +e
(
    set -e
    ACTION=install-panel; COMPONENT=panel; VERSION=1.1.1; YES=true
    ROOT="$fixture/new-root"; WORK="$fixture/new-work"; LOG="$fixture/new-install.log"
    mkdir -p "$WORK" "$ROOT/registry"
    prepare_host() { :; }; lock_operation() { :; }; prepare_image() { :; }
    assert_fresh_target() { :; }; certificate_wizard() { :; }; certificate_preflight() { :; }; obtain_certificate() { :; }; configure_certificate() { :; }; port_free() { :; }
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
    install_cli "$fixture/cli-bin" "$fixture/helper-cache"
    python3 - "$project" "$fixture/cli-bin/remnacust" <<'PY'
import sys,pathlib
sys.path.insert(0,sys.argv[1]);import helper_bundle
assert helper_bundle.canonical(pathlib.Path(sys.argv[1]+'/installer.sh').read_bytes())==helper_bundle.canonical(pathlib.Path(sys.argv[2]).read_bytes())
assert helper_bundle.embedded(pathlib.Path(sys.argv[2]).read_bytes()) is not None
PY
    # Calling the installed entry again must work when its destination already exists.
    source "$fixture/cli-bin/remnacust"
    WORK="$fixture/cli-work"; SOURCE="$fixture/old-source"
    install_cli "$fixture/cli-bin" "$fixture/helper-cache"
    bash -n "$fixture/cli-bin/remnacust"
)
pass 'installing an older bundle preserves current CLI policy and supports self-update'
make_patch_release() {
    python3 - "$fixture" "$1" "${2:-1.1.1}" "${3:-1.1.2}" <<'PY'
import hashlib,json,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]);source=root/'archive';version=sys.argv[2];panel_version=sys.argv[3]
release_version=sys.argv[4];tag='v'+release_version
(source/'VERSION').write_text(release_version+'\n')
(source/'component-sources.json').write_text(json.dumps({kind:{'repository':'lottman/Remnacust-'+kind,'commit':'a'*40,'version':version if kind=='node' else panel_version if kind=='panel' else '1.1.1'} for kind in ['panel','node','core']}))
for package in ['panel/frontend','panel/backend','subscription-page/frontend','subscription-page/backend']:
    (source/package/'package.json').write_text(json.dumps({'version':panel_version}))
name='remnacust-source-'+tag+'.tar.gz'
with tarfile.open(root/name,'w:gz') as archive:archive.add(source,arcname='.')
digest=hashlib.sha256((root/name).read_bytes()).hexdigest()
(root/('SHA256SUMS-'+tag)).write_text(digest+'  '+name+'\n')
release=dict(tag_name=tag,draft=False,prerelease=False,assets=[])
for asset,local in [(name,name),('SHA256SUMS','SHA256SUMS-'+tag)]:
    release['assets'].append(dict(name=asset,state='uploaded',browser_download_url='https://github.com/lottman/Remnacust-installer/releases/download/'+tag+'/'+asset,digest='sha256:'+hashlib.sha256((root/local).read_bytes()).hexdigest()))
(root/('release-'+tag+'.json')).write_text(json.dumps(release))
PY
}
make_patch_release 1.1.1
bash "$project/installer.sh" --check-release --version 1.1.2 > "$fixture/result"
pass 'installer patch accepts independently pinned application versions'
make_patch_release 1.1.1 1.1.7.1
bash "$project/installer.sh" --check-release --version 1.1.2 > "$fixture/result"
pass 'downloaded source accepts four-part panel and subscription versions'
mkdir -p "$fixture/control"
REMNACUST_RELEASE_INFO_FILE="$fixture/control/release.json" REMNACUST_RELEASE_ENTRY_FILE="$fixture/control/installer.sh" \
    bash "$project/installer.sh" --check-release --version 1.1.2 > "$fixture/result"
python3 - "$fixture/control" "$project" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
sys.path.insert(0,sys.argv[2]);import helper_bundle
assert helper_bundle.canonical((root/'installer.sh').read_bytes())==helper_bundle.canonical(pathlib.Path(sys.argv[2]+'/installer.sh').read_bytes())
assert helper_bundle.embedded((root/'installer.sh').read_bytes()) is not None
assert json.loads((root/'release.json').read_text())=={'installerVersion':'1.1.2','panelVersion':'1.1.7.1'}
assert (root/'installer.sh').stat().st_mode&0o777==0o600
PY
pass 'self-update exports the verified installer entry and panel version with private permissions'
(
    # The exported entry also works when the old installation has no helper contract.
    source "$fixture/control/installer.sh"
    WORK="$fixture/export-work";mkdir -p "$WORK"
    download(){ echo UNEXPECTED_NETWORK >&2; return 99; }
    installed_helper; helper --help | grep -q plan-panel-data-restore
)
pass 'exported entry carries its restore planner without legacy or online helpers'
new_version=$(python3 - "$project/../VERSION" <<'PY'
import pathlib,sys
major,minor,patch=map(int,pathlib.Path(sys.argv[1]).read_text().strip().split('.'))
print(f'{major}.{minor}.{patch+1}')
PY
)
python3 - "$project" "$fixture/archive" "$new_version" <<'PY'
import pathlib,shutil,sys
sys.path.insert(0,sys.argv[1]);import helper_bundle
source=pathlib.Path(sys.argv[1]);target=pathlib.Path(sys.argv[2])
for name in helper_bundle.FILES:
    shutil.copyfile(source.parent/name if name in {'LICENSE','NOTICE.md'} else source/name,target/name if name in {'LICENSE','NOTICE.md'} else target/'installer'/name)
(target/'installer/installer.sh').write_bytes((source/'installer.sh').read_bytes()+b'\n# next fixture entry\n')
(target/'VERSION').write_text(sys.argv[3]+'\n');helper_bundle.sync(target)
PY
make_patch_release 1.1.1 1.1.7.1 "$new_version"
REMNACUST_RELEASE_INFO_FILE="$fixture/control/release.json" REMNACUST_RELEASE_ENTRY_FILE="$fixture/control/installer.sh" \
    bash "$project/installer.sh" --check-release --version "$new_version" > "$fixture/result"
python3 - "$project" "$fixture/control/installer.sh" "$new_version" <<'PY'
import pathlib,sys
sys.path.insert(0,sys.argv[1]);import helper_bundle
entry=pathlib.Path(sys.argv[2]).read_bytes();raw,files=helper_bundle.embedded(entry)
assert helper_bundle.manifest(raw)['version']==sys.argv[3]
assert b'# next fixture entry' in helper_bundle.code(entry)
assert helper_bundle.validate(entry,raw,files)
PY
pass 'self-update selects the paired entry and complete cohort from a newer release'
make_patch_release 1.1.1 1.1.7.1.1
reject 'five-part panel versions remain invalid' bash "$project/installer.sh" --check-release --version 1.1.2
grep -q 'Неверная версия компонента: panel' "$fixture/result"
make_patch_release 1.1.1.1 1.1.7.1
reject 'four-part versions are limited to the panel' bash "$project/installer.sh" --check-release --version 1.1.2
grep -q 'Неверная версия компонента: node' "$fixture/result"
make_patch_release 1.1.0
reject 'valid archive checksum cannot conceal an incorrect pinned component version' bash "$project/installer.sh" --check-release --version 1.1.2
grep -q 'Версия исходников не совпадает с закреплённым компонентом: node' "$fixture/result"
WORK=''
printf 'Installer bootstrap checks passed.\n'
