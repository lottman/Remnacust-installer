#!/usr/bin/env bash
# Exercise the downloaded entry point without installed helpers, Compose or network.
set -Eeuo pipefail
[[ $EUID == 0 ]] || exec sudo env PATH="$PATH" bash "$0" "$@"
installer=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t remnacust-uninstall.XXXXXXXX)
trap '[[ $fixture == /tmp/remnacust-uninstall.* ]] && rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
export FIXTURE=$fixture
cat > "$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['FIXTURE']);args=sys.argv[1:];data=json.loads((p/'containers.json').read_text())
with (p/'requests').open('a') as f:f.write(' '.join(args)+'\n')
if args[0]=='ps':
 if os.environ.get('MOCK_DAEMON_DOWN'):raise SystemExit(1)
 if '--filter' in args:
  for i,arg in enumerate(args[:-1]):
   if arg=='--filter':
    label=args[i+1].removeprefix('label=');key,_,value=label.partition('=')
    data=[c for c in data if c['Config']['Labels'].get(key)==value]
 for c in data:
  if '--format' in args:print(c['Id']+'|'+c['Config']['Labels']['com.docker.compose.project']+'|'+c['Config']['Image'])
  else:print(c['Id'])
elif args[0]=='inspect':
 selected=[c for c in data if c['Id'] in args[1:]]
 if len(selected)!=len(args)-1:raise SystemExit(1)
 print(json.dumps(selected))
elif args[0]=='stop':pass
elif args[0]=='rm':
 if os.environ.get('MOCK_REMOVE_FAIL'):raise SystemExit(1)
 (p/'containers.json').write_text(json.dumps([c for c in data if c['Id'] not in args[2:]]))
 if os.environ.get('MOCK_REMOVED_RACE'):raise SystemExit(1)
else:raise SystemExit('Unexpected Docker command')
MOCK
cat > "$fixture/bin/curl" <<'MOCK'
#!/usr/bin/env bash
touch "$FIXTURE/unexpected-network"
exit 1
MOCK
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
prepare_case() {
 export REMNACUST_ROOT="$fixture/$1/root" CASE=$1
 mkdir -p "$REMNACUST_ROOT/registry"
 rm -f "$fixture/requests"
 python3 - "$fixture" "$1" <<'PY'
import json,sys,os
from pathlib import Path
p=Path(sys.argv[1]);case=sys.argv[2];root=Path(os.environ['REMNACUST_ROOT'])
def c(n,project,service,image,running=True,role=''):
 return {'Id':format(n,'064x'),'Name':'/'+project+'-'+service+'-'+str(n),'Config':{'Image':image,'Labels':{'com.docker.compose.project':project,'com.docker.compose.service':service,'com.docker.compose.project.working_dir':str(p/'lost-directory'),'com.docker.compose.project.config_files':str(p/'lost-directory/docker-compose.yml')},'Env':['INSTANCE_TYPE='+role] if role else []},'State':{'Running':running}}
own=[c(1,'remnacust-panel','remnawave','ghcr.io/lottman/remnacust-panel:1.1.2',False),c(2,'remnacust-panel','remnawave-db','postgres:18.4'),c(3,'remnacust-panel','caddy','caddy:2-alpine')]
foreign=c(9,'other-project','postgres','postgres:18.4')
if case=='infra':own=own[1:]
if case=='migrated':
 own=[c(1,'upstream','remnawave','ghcr.io/lottman/remnacust-panel:1.1.2'),c(2,'upstream','processor','ghcr.io/lottman/remnacust-panel:1.1.2',role='processor'),c(3,'upstream','caddy','caddy:2-alpine'),c(4,'upstream','database','postgres:17.6')]
elif case=='registered':
 own=[c(1,'custom-project','api','ghcr.io/lottman/remnacust-panel:1.1.2'),c(2,'custom-project','caddy','caddy:2-alpine')]
 (root/'registry/panel.json').write_text(json.dumps({'component':'panel','directory':str(p/'lost-directory'),'project':'custom-project','composeFiles':[str(p/'lost-directory/compose.json')],'mainService':'api','applications':['api'],'extraServices':[],'ownedServices':['api']}))
elif case=='multiple':own.append(c(5,'another-remnacust','remnawave','ghcr.io/lottman/remnacust-panel:1.1.2'))
elif case=='node':
 own=[c(1,'remnacust-node','remnanode','ghcr.io/lottman/remnacust-node:1.1.1',False),c(2,'remnacust-node','node-nginx','nginx:1.28-alpine')]
elif case=='files':
 directory=p/'original-directory';directory.mkdir()
 compose=directory/'compose.yml';compose.write_text('services: {}\n')
 (directory/'.env').write_text('APP_SECRET=preserved-test-secret\n')
 (root/'registry/panel.json').write_text(json.dumps({'component':'panel','directory':str(directory),'project':'remnacust-panel','composeFiles':[str(compose)],'mainService':'remnawave','applications':['remnawave'],'extraServices':['caddy'],'ownedServices':['remnawave','remnawave-db','caddy'],'tls':{'method':'existing'},'panelDomain':'panel.example.org'}))
(p/'containers.json').write_text(json.dumps(own+[foreign]))
PY
}
check_no_compose_or_network() {
 ! grep -qE '^compose|^pull|^image|--volumes|prune|^volume' "$fixture/requests"
 [[ ! -f $fixture/unexpected-network ]]
}
prepare_case missing
bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output"
python3 - "$fixture" "$REMNACUST_ROOT" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);root=Path(sys.argv[2]);remaining=json.load(open(p/'containers.json'))
assert [int(c['Id'],16) for c in remaining]==[9]
state=json.load(open(root/'registry/panel.json'));assert state['uninstalled'] and not state['recoverable']
backup=Path(state['uninstallSnapshot']);assert len(json.load(open(backup/'containers.json')))==3
assert backup.stat().st_mode&0o777==0o700
assert (backup/'containers.json').stat().st_mode&0o777==0o600
assert not (p/'lost-directory').exists()
PY
check_no_compose_or_network
cp "$REMNACUST_ROOT/registry/panel.json" "$fixture/previous-uninstall.json"
bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output"
python3 - "$fixture/previous-uninstall.json" "$REMNACUST_ROOT/registry/panel.json" <<'PY'
import json,sys
before,after=[json.load(open(p)) for p in sys.argv[1:]]
assert before['directory']==after['directory'] and after['uninstalled']
PY
printf 'PASS repeated removal tolerates an already-deleted installation\n'
printf 'PASS missing Compose, registry and directory do not prevent removal; stopped app and owned infrastructure removed\n'
prepare_case migrated
bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output"
python3 - "$fixture/containers.json" <<'PY'
import json,sys
assert sorted(int(c['Id'],16) for c in json.load(open(sys.argv[1])))==[3,4,9]
PY
check_no_compose_or_network
printf 'PASS migrated app and worker removed while shared proxy, database and unrelated project remain\n'
prepare_case registered
bash "$installer/installer.sh" uninstall-panel --yes --container custom-project-api-1 > "$fixture/output"
python3 - "$fixture/containers.json" <<'PY'
import json,sys
assert sorted(int(c['Id'],16) for c in json.load(open(sys.argv[1])))==[2,9]
PY
printf 'PASS registry ownership is respected even with missing files and explicit container\n'
prepare_case node
bash "$installer/installer.sh" uninstall-node --yes > "$fixture/output"
python3 - "$fixture/containers.json" <<'PY'
import json,sys
assert [int(c['Id'],16) for c in json.load(open(sys.argv[1]))]==[9]
PY
printf 'PASS node and its own Nginx removed without Compose\n'
prepare_case infra
bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output"
python3 - "$fixture/containers.json" <<'PY'
import json,sys
assert [int(c['Id'],16) for c in json.load(open(sys.argv[1]))]==[9]
PY
printf 'PASS own infrastructure can be removed when the application container has already disappeared\n'
prepare_case files
bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output"
python3 - "$fixture" "$REMNACUST_ROOT" <<'PY'
import json,sys
from pathlib import Path
p,root=map(Path,sys.argv[1:]);s=json.load(open(root/'registry/panel.json'))
assert not s['recoverable'] and s['reinstallOnly'] and s['uninstalled'] and s['tls']=={'method':'existing'}
assert s['panelDomain']=='panel.example.org'
assert (p/'original-directory/.env').read_text()=='APP_SECRET=preserved-test-secret\n'
assert (p/'original-directory/compose.yml').read_text()=='services: {}\n'
assert (p/'original-directory/.remnacust-uninstalled').is_file()
PY
bash -c 'source "$1"; retired_installation panel; show_menu' _ "$installer/installer.sh" > "$fixture/menu"
grep -Eq '^[[:space:]]*1[[:space:]]+install-panel' "$fixture/menu"
! grep -q 'start --component panel' "$fixture/menu"
! grep -q 'Для возврата' "$fixture/output"
grep -q 'Повторная установка: remnacust install-panel' "$fixture/output"
cp "$fixture/requests" "$fixture/requests.before"
for action in start restart restore-panel; do
    if bash "$installer/installer.sh" "$action" --component panel --yes > "$fixture/output" 2>&1; then exit 1; fi
    grep -q 'Доступна только новая установка' "$fixture/output"
    cmp "$fixture/requests" "$fixture/requests.before"
done
printf 'PASS retained Compose, secrets and TLS metadata are preserved; only fresh installation is offered and deleted deployments cannot be started or restored\n'
prepare_case multiple
if bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'несколько установок' "$fixture/output"
! grep -qE '^stop|^rm' "$fixture/requests"
printf 'PASS ambiguous installation selection stops before destructive commands\n'
prepare_case failure
export MOCK_REMOVE_FAIL=1
if bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output" 2>&1; then exit 1; fi
[[ ! -f $REMNACUST_ROOT/registry/panel.json ]]
unset MOCK_REMOVE_FAIL
printf 'PASS failed Docker removal is not recorded as successful\n'
prepare_case race
export MOCK_REMOVED_RACE=1
bash "$installer/installer.sh" uninstall-panel --yes > "$fixture/output"
unset MOCK_REMOVED_RACE
printf 'PASS actual inventory verifies success when Docker reports an already-removed container\n'
check_no_compose_or_network
