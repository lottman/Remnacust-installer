#!/usr/bin/env python3
"""Exercise data-only restore against disposable Compose/PostgreSQL fixtures.

The tiny image tests installer orchestration, not the complete product image.
It deliberately contains no product server or financial coordinator.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    if os.name == 'nt':
        raise SystemExit('Run this Docker integration test on Linux')
    installer = Path(__file__).resolve().parents[1]
    suffix = uuid.uuid4().hex[:12]
    project = 'remnacust-restore-test-' + suffix
    image = project + ':fixture'
    root = Path(tempfile.mkdtemp(prefix=project + '-'))
    deployment = root / 'deployment'
    deployment.mkdir()
    config = deployment / 'compose.json'
    try:
        sys.path.insert(0, str(installer))
        import helper_bundle
        entry, contract, files = helper_bundle.source_bundle(installer.parent)
        legacy = root / 'legacy-cli'; legacy.mkdir()
        (legacy / 'installer.sh').write_bytes(helper_bundle.render(entry, contract, files))
        (legacy / 'runtime.py').write_text('raise SystemExit("legacy runtime executed")\n')
        (legacy / 'database.cjs').write_text('throw Error("legacy database executed");\n')
        (root / 'Dockerfile').write_text('FROM postgres:18.4\nCOPY --from=node:24.22.1-trixie-slim /usr/local/bin/node /usr/local/bin/node\nWORKDIR /fixture\nCOPY database-compatibility.js dist/database-compatibility.js\nENTRYPOINT ["node"]\nCMD ["-e", "setInterval(()=>{},1000)"]\n')
        (root / 'database-compatibility.js').write_text(r"""
const {spawnSync}=require('node:child_process');
const u=new URL(process.env.DATABASE_URL);
const env={...process.env,PGHOST:u.hostname,PGUSER:u.username,PGDATABASE:u.pathname.slice(1)};
const read=sql=>spawnSync('psql',['-At','--set','ON_ERROR_STOP=on','-c',sql],{env,encoding:'utf8'});
const result=read('SELECT expected_key,fail FROM fixture_control');
if(result.status!==0)process.exit(1);
const [expected,fail]=result.stdout.trim().split('|');
if(process.env.APP_SECRET!==expected||fail==='t')process.exit(41);
if(read('ALTER TABLE users ADD COLUMN IF NOT EXISTS restored_by_current boolean DEFAULT true').status!==0)process.exit(1);
""")
        run('docker', 'build', '--pull=false', '--network=none', '-t', image, str(root), stdout=subprocess.DEVNULL)
        (root / 'setup.py').write_text(r"""
import copy,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);deployment=root/'deployment';project=sys.argv[2];image=sys.argv[3]
secret='backup-literal-$-key-'+'b'*40
(deployment/'.env').write_text('UNRELATED_SETTING=keep-current\n')
url='postgresql://postgres@database:5432/postgres'
app=dict(image=image,stop_grace_period='1s',environment={'DATABASE_URL':url,'APP_SECRET':secret.replace('$','$$')},healthcheck={'test':['CMD','node','-e','process.exit(0)'],'interval':'1s','timeout':'1s','retries':3})
c={'name':project,'services':{'api':app,'worker':copy.deepcopy(app),'standby':{**copy.deepcopy(app),'profiles':['standby']},'database':{'image':'postgres:18.4','environment':{'POSTGRES_HOST_AUTH_METHOD':'trust'},'volumes':['database:/var/lib/postgresql']}},'volumes':{'database':{}}}
(deployment/'compose.json').write_text(json.dumps(c))
s=dict(schema=1,component='panel',directory=str(deployment),project=project,version='1.1.9',image=image,mainService='api',applications=['api','worker','standby'],extraServices=[],composeFiles=[str(deployment/'compose.json')])
(root/'state.json').write_text(json.dumps(s))
(root/'secret').write_text(secret)
""")
        run('python3', str(root / 'setup.py'), str(root), project, image)
        harness = root / 'exercise.sh'
        harness.write_text(r"""#!/usr/bin/env bash
set -Eeuo pipefail
export REMNACUST_ROOT="$1/control"
source "$2/installer.sh"
ROOT=$REMNACUST_ROOT; COMPONENT=panel; SOURCE=$3; YES=true
STATE="$1/state.json"; LOG="$1/operation.log"; WORK="$1/work-setup";mkdir -p "$WORK" "$ROOT/registry"
installed_helper
python3 - "$ROOT/update-agent.json" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'token':'a'*64}))
PY
load_state
compose up -d database api worker > /dev/null
compose --profile standby up --no-start --no-deps --no-build --pull never standby > /dev/null
for ((attempt=0;attempt<45;attempt++)); do
 if compose exec -T database pg_isready -U postgres >/dev/null;then break;fi
 sleep 1
done
secret=$(cat "$1/secret")
compose exec -T database psql -U postgres -v ON_ERROR_STOP=1 > /dev/null <<SQL
CREATE TABLE users(id int PRIMARY KEY, username text);
INSERT INTO users VALUES(1,'backed-up-user');
CREATE TABLE fixture_control(expected_key text,fail boolean);
INSERT INTO fixture_control VALUES('$secret',false);
CREATE TABLE fixture_quarantine(pending boolean);
INSERT INTO fixture_quarantine VALUES(false);
CREATE FUNCTION xera_quarantine_restored_quotas() RETURNS void LANGUAGE sql AS 'UPDATE fixture_quarantine SET pending=true';
SQL
START_APPS=(api worker);wait_ready
main_id=$(compose ps --quiet api);db_id=$(compose ps --quiet database)
docker inspect "$main_id" > "$WORK/container.before.json"
database_environment
backup_current
requested=$BACKUP
# Make the archived deployment unmistakably obsolete. Only its data/key should return.
python3 - "$requested" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);s=json.load(open(p/'state.before.json'));s['version']='1.1.2';s['image']='postgres:17.6';(p/'state.before.json').write_text(json.dumps(s))
c=json.load(open(p/'compose.before.json'));c['services']['database']['image']='postgres:17.6';c['services']['api']['image']='postgres:17.6';(p/'compose.before.json').write_text(json.dumps(c))
PY
helper hash-backup --directory "$requested"
cp "$requested/SHA256SUMS" "$1/backup-checksums"
python3 - "$DEPLOY" "$STATE" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);c=json.load(open(p/'compose.json'))
for name in ['api','worker','standby']:c['services'][name]['environment']['APP_SECRET']='current-key-'+'c'*48
(p/'compose.json').write_text(json.dumps(c));layer=p/'compose.override.yaml';layer.write_text('{"services":{"api":{"environment":{"UNRELATED_FLAG":"keep"}}}}')
s=json.load(open(sys.argv[2]));s['composeFiles'].append(str(layer));pathlib.Path(sys.argv[2]).write_text(json.dumps(s))
PY
load_state;compose up -d --no-deps api worker >/dev/null
compose exec -T database psql -U postgres -c "INSERT INTO users VALUES(2,'not-in-backup')" >/dev/null
WORK="$1/work-restore";mkdir -p "$WORK"
BACKUP=$requested;restore_panel
[[ $(compose ps --quiet database) == "$db_id" ]]
[[ $(docker inspect --format '{{.Config.Image}}' "$db_id") == postgres:18.4 ]]
[[ $(compose exec -T database psql -U postgres -Atc 'SELECT count(*) FROM users') == 1 ]]
[[ $(compose exec -T database psql -U postgres -Atc 'SELECT restored_by_current FROM users') == t ]]
[[ $(compose exec -T database psql -U postgres -Atc 'SELECT pending FROM fixture_quarantine') == t ]]
[[ $(docker inspect --format '{{.State.Running}}' "$(compose ps --all --quiet standby)") == false ]]
cmp "$requested/SHA256SUMS" "$1/backup-checksums"
helper verify-backup --directory "$requested"
python3 - "$STATE" "$DEPLOY/compose.json" "$DEPLOY/compose.override.yaml" "$DEPLOY/.env" <<'PY'
import json,pathlib,sys
s=json.load(open(sys.argv[1]));c=json.load(open(sys.argv[2]));assert s['version']=='1.1.9'
assert all(c['services'][name]['image']==s['image'] for name in ['api','worker','standby'])
assert s['image'].startswith('sha256:') and c['services']['database']['image']=='postgres:18.4'
assert c['services']['api']['environment']['UNRELATED_FLAG']=='keep'
assert json.load(open(sys.argv[3]))=={'services':{}}
assert pathlib.Path(sys.argv[4]).read_text()=='UNRELATED_SETTING=keep-current\n'
PY
printf 'PASS older backup retains installed writers, database, key, layers and stopped worker\n'
# Entirely offline backup stays offline after restore, including a recreated API.
compose stop "${APPS[@]}" >/dev/null
WORK="$1/work-offline-backup";mkdir -p "$WORK"
docker inspect "$(compose ps --all --quiet api)" > "$WORK/container.before.json"
database_environment;backup_current;offline=$BACKUP
compose up -d --no-deps api >/dev/null
WORK="$1/work-offline-restore";mkdir -p "$WORK";BACKUP=$offline;restore_panel
for name in api worker standby;do [[ $(docker inspect --format '{{.State.Running}}' "$(compose ps --all --quiet "$name")") == false ]];done
printf 'PASS fully offline backup never starts an application\n'
# Migration error after SQL commit must retain matching key and installed image in registry/container.
compose exec -T database psql -U postgres -c 'UPDATE fixture_control SET fail=true' >/dev/null
WORK="$1/work-failing-backup";mkdir -p "$WORK"
docker inspect "$(compose ps --all --quiet api)" > "$WORK/container.before.json"
database_environment;backup_current;failing=$BACKUP
python3 - "$DEPLOY/compose.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);c=json.load(open(p))
for name in ['api','worker','standby']:c['services'][name]['environment']['APP_SECRET']='different-key-'+'d'*48
p.write_text(json.dumps(c))
PY
compose up -d --no-deps api >/dev/null
WORK="$1/work-failing-restore";mkdir -p "$WORK";BACKUP=$failing
# Run as its own shell so ERR semantics remain enabled (no `if restore_panel`).
export FIXTURE_ROOT="$1" FIXTURE_INSTALLER="$2" FIXTURE_SOURCE="$3" FIXTURE_STATE="$STATE" FIXTURE_BACKUP="$failing"
cat > "$1/failing.sh" <<'SH'
set -Eeuo pipefail
source "$FIXTURE_INSTALLER/installer.sh"
ROOT=$REMNACUST_ROOT;COMPONENT=panel;SOURCE=$FIXTURE_SOURCE;YES=true
STATE=$FIXTURE_STATE;WORK="$FIXTURE_ROOT/work-failing-restore";LOG="$FIXTURE_ROOT/failing.log";BACKUP=$FIXTURE_BACKUP
installed_helper
load_state
restore_panel
SH
set +e
bash "$1/failing.sh" > "$1/failure-output" 2>&1
failure=$?
set -e
[[ $failure != 0 ]]
STATE="$ROOT/registry/panel.json";load_state
docker inspect "$(compose ps --all --quiet api)" > "$1/failed-api.json"
python3 - "$1/failed-api.json" "$1/secret" "$STATE" <<'PY'
import json,pathlib,sys
c=json.load(open(sys.argv[1]))[0];e=dict(item.split('=',1) for item in c['Config']['Env'] if '=' in item)
assert e['APP_SECRET']==pathlib.Path(sys.argv[2]).read_text()
assert not c['State']['Running'] and c['Image']==json.load(open(sys.argv[3]))['image']
import hashlib,hmac
state=json.load(open(sys.argv[3]));root=pathlib.Path(sys.argv[3]).parents[1]
expected=hmac.new(e['APP_SECRET'].encode(),b'remnacust-panel-update-v1',hashlib.sha256).hexdigest()
assert json.load(open(root/'update-agent.json'))=={'token':expected}
PY
for name in api worker standby;do [[ $(docker inspect --format '{{.State.Running}}' "$(compose ps --all --quiet "$name")") == false ]];done
# A later independent backup uses the matching restored key and succeeds.
WORK="$1/work-after-failure";mkdir -p "$WORK"
docker inspect "$(compose ps --all --quiet api)" > "$WORK/container.before.json"
database_environment;backup_current
helper verify-backup --directory "$BACKUP"
printf 'PASS failed migration keeps writers stopped with restored identity and supports retry backup\n'
""")
        run('bash', str(harness), str(root), str(legacy), str(installer.parent))
    except Exception:
        for name in ['operation.log', 'failure-output', 'failing.log']:
            path = root / name
            if path.exists():
                print(path.read_text()[-12000:])
        raise
    finally:
        if config.exists():
            subprocess.run(['docker', 'compose', '--project-name', project, '--project-directory', str(deployment), '-f', str(config), '--profile', '*', 'down', '--volumes', '--remove-orphans'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        subprocess.run(['docker', 'image', 'rm', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if root.parent == Path(tempfile.gettempdir()) and root.name.startswith(project + '-'):
            shutil.rmtree(root)


if __name__ == '__main__':
    main()
