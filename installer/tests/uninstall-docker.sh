#!/usr/bin/env bash
# Test the standalone entry point against real containers; never use an existing project.
set -Eeuo pipefail
[[ $EUID == 0 ]] || exec sudo env PATH="$PATH" bash "$0" "$@"
installer=${1:-$(cd "$(dirname "$0")/.." && pwd)/installer.sh}
fixture=$(mktemp -d -t remnacust-uninstall-docker.XXXXXXXX)
token="remnacust-uninstall-test-$(date +%s)-$$"
export REMNACUST_ROOT="$fixture/root"
declare -a containers=() volumes=()
cleanup_test() {
    local id volume
    for id in "${containers[@]}"; do docker rm --force "$id" >/dev/null 2>&1 || true; done
    for volume in "${volumes[@]}"; do docker volume rm "$volume" >/dev/null 2>&1 || true; done
    [[ $fixture == /tmp/remnacust-uninstall-docker.* ]] && rm -rf -- "$fixture"
}
trap cleanup_test EXIT
docker image inspect alpine:3.22 >/dev/null 2>&1 || docker pull alpine:3.22 >/dev/null
docker volume create "$token-data" >/dev/null; volumes+=("$token-data")
docker run --rm -v "$token-data:/data" alpine:3.22 sh -c 'printf retained-data > /data/sentinel'
create_container() {
    local project=$1 service=$2 managed=$3; shift 3
    local -a labels=(--label "com.docker.compose.project=$project" --label "com.docker.compose.service=$service"
        --label "com.docker.compose.project.working_dir=$fixture/lost-directory"
        --label "com.docker.compose.project.config_files=$fixture/lost-directory/docker-compose.yml")
    [[ $managed != yes ]] || labels+=(--label io.remnacust.installer-managed=panel)
    last=$(docker run -d --name "$project-$service" "${labels[@]}" "$@" alpine:3.22 sleep 600)
    containers+=("$last")
}
foreign_project="$token-unrelated"
create_container "$foreign_project" nginx no; foreign=$last
docker inspect "$foreign" > "$fixture/foreign.before.json"
own_project="$token-owned"
create_container "$own_project" remnawave yes; app=$last
docker stop --time 1 "$app" >/dev/null
create_container "$own_project" database yes -v "$token-data:/data"; database=$last
create_container "$own_project" caddy yes; proxy=$last
bash "$installer" uninstall-panel --project-name "$own_project" --yes
for id in "$app" "$database" "$proxy"; do ! docker inspect "$id" >/dev/null 2>&1; done
[[ ! -e $fixture/lost-directory ]]
docker run --rm -v "$token-data:/data:ro" alpine:3.22 grep -qx retained-data /data/sentinel
python3 - "$REMNACUST_ROOT/registry/panel.json" <<'PY'
import json,sys
from pathlib import Path
s=json.load(open(sys.argv[1]));assert s['uninstalled'] and not s['recoverable']
p=Path(s['uninstallSnapshot']);assert len(json.load(open(p/'containers.json')))==3
assert p.stat().st_mode&0o777==0o700 and (p/'containers.json').stat().st_mode&0o777==0o600
PY
printf 'PASS real Docker removes stopped app and owned infrastructure without Compose; volume data remains\n'

export REMNACUST_ROOT="$fixture/migrated-root"
migrated_project="$token-migrated"
create_container "$migrated_project" remnawave no; app=$last
create_container "$migrated_project" processor no -e INSTANCE_TYPE=processor; worker=$last
create_container "$migrated_project" caddy no; proxy=$last
create_container "$migrated_project" postgres no -v "$token-data:/data"; database=$last
docker inspect "$proxy" "$database" > "$fixture/shared.before.json"
bash "$installer" uninstall-panel --project-name "$migrated_project" --yes
! docker inspect "$app" >/dev/null 2>&1
! docker inspect "$worker" >/dev/null 2>&1
docker inspect "$proxy" "$database" > "$fixture/shared.after.json"
docker inspect "$foreign" > "$fixture/foreign.after.json"
python3 - "$fixture" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
for name in ['shared','foreign']:
    before=json.load(open(p/(name+'.before.json')));after=json.load(open(p/(name+'.after.json')))
    assert len(before)==len(after)
    for a,b in zip(before,after):
        for key in ['Id','Config','HostConfig','Mounts','State']:
            assert a[key]==b[key],(name,key)
PY
printf 'PASS real Docker preserves shared proxy/database and unrelated project without restarting them\n'
