#!/usr/bin/env bash
# Disposable Docker project. Never run against an existing installation.
set -Eeuo pipefail
installer_dir=$(cd "$(dirname "$0")/.." && pwd)
public_source=${1:?Pass a public source tree}
test_image=${2:-remnacust-panel:1.1.1-20261006-public-key}
test_root=$(mktemp -d -t remnacust-integration.XXXXXXXX)
test_project="remnacust-installer-test-$$"
test_log="$test_root/operation.log"
cleanup_test() {
    local result=$?
    if ((result)); then
        cat "$test_log" 2>/dev/null || true
        local app_id; app_id=$(docker ps -aq --filter "label=com.docker.compose.project=$test_project" --filter label=com.docker.compose.service=remnawave)
        [[ -z $app_id ]] || docker logs --tail 70 "$app_id" 2>&1 || true
        docker ps -a --filter "label=com.docker.compose.project=$test_project" --format '{{.Names}} {{.Status}}'
    fi
    docker compose --project-name "$test_project" -f "$test_root/deploy/compose.json" down --volumes --remove-orphans >/dev/null 2>&1 || true
    [[ $test_root == /tmp/remnacust-integration.* ]] && rm -rf -- "$test_root"
}
trap cleanup_test EXIT
export REMNACUST_ROOT="$test_root/root"
source "$installer_dir/installer.sh"
ROOT=$REMNACUST_ROOT; WORK="$test_root/work"; mkdir -p "$WORK" "$ROOT/registry"
LOG=$test_log; SOURCE=$public_source; HELPER="$installer_dir/runtime.py"
COMPONENT=panel; ACTION=install-panel; PROXY=existing; DOMAIN=panel.example.com; PORT=43873
DIRECTORY="$test_root/deploy"; PROJECT=$test_project; IMAGE=remnawave/backend:3.4.4
fresh_files
# Start upstream with PostgreSQL 17: migration must not upgrade the database or change its mount.
python3 - "$DEPLOY/compose.json" <<'PY'
import json,sys
p=sys.argv[1];c=json.load(open(p));s=c['services']['remnawave-db'];s['image']='postgres:17.6';s['volumes']=['database:/var/lib/postgresql/data'];json.dump(c,open(p,'w'))
PY
python3 - "$DEPLOY/compose.json" <<'PY'
import copy,json,sys
p=sys.argv[1];c=json.load(open(p));worker=copy.deepcopy(c['services']['remnawave'])
worker.pop('ports',None);worker.pop('healthcheck',None)
worker['environment']={'INSTANCE_TYPE':'processor'};worker['profiles']=['standby']
c['services']['standby-worker']=worker;json.dump(c,open(p,'w'))
PY
compose up -d >/dev/null
compose --profile standby create standby-worker >/dev/null
step 'Upstream ready' wait_ready
compose exec -T remnawave-db sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null <<'SQL'
INSERT INTO users (username,short_uuid,vless_uuid,trojan_password,ss_password,expire_at) VALUES ('installer_fixture','installer-fixture-uuid','bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb','fixture-password','fixture-password',now()+interval '1 year');
INSERT INTO admin (username,password_hash,role) VALUES ('fixture-admin','fixture-hash','ADMIN');
INSERT INTO config_profiles (name,config) SELECT 'fixture-profile',jsonb_set(config,'{inbounds}',(SELECT jsonb_agg(jsonb_set(x,'{tag}',to_jsonb('fixture-'||(x->>'tag')))) FROM jsonb_array_elements(config->'inbounds') x)) FROM config_profiles LIMIT 1;
SQL
old_id=$(compose ps --quiet remnawave); old_db=$(compose ps --quiet remnawave-db)
prepare_host() { docker info >/dev/null; }
release_source() { TAG=v1.1.1; SOURCE=$public_source; HELPER="$installer_dir/runtime.py"; IMAGE=$test_image; }
build_image() { docker image inspect "$IMAGE" >/dev/null; }
install_cli() { :; }
YES=true; VERSION=latest; ACTION=migrate-remnawave-panel; CONTAINER=$old_id; DIRECTORY=''
deploy
new_id=$(compose ps --quiet remnawave)
[[ $old_id != "$new_id" && $(compose ps --quiet remnawave-db) == "$old_db" ]]
[[ $(docker inspect --format '{{.Config.Image}}' "$old_db") == postgres:17.6 ]]
[[ -s $BACKUP/database.dump && -s $BACKUP/fingerprints.json ]]
printf 'PASS real upstream -> custom migration preserves PostgreSQL 17, users, keys, admin, profiles and mounts\n'
# Update from a historic fork state with the formerly renamed tables and encrypted credentials.
compose stop remnawave >/dev/null
docker inspect "$new_id" > "$WORK/container.before.json"; database_environment
docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$test_image" - <<'JS'
const {PrismaClient}=require('@prisma/client'),crypto=require('crypto');const p=new PrismaClient();
(async()=>{const k=crypto.createHmac('sha256',process.env.APP_SECRET).update('xera-keyring-v1').digest();const iv=crypto.randomBytes(12),c=crypto.createCipheriv('aes-256-gcm',k,iv);const encrypted=Buffer.concat([c.update('fixture-password'),c.final()]);const value='xera1:'+Buffer.concat([iv,c.getAuthTag(),encrypted]).toString('base64');
await p.$executeRawUnsafe('UPDATE users SET trojan_password=$1, ss_password=$1 WHERE username=$2',value,'installer_fixture');
await p.$executeRawUnsafe('ALTER TABLE admin RENAME TO xera_admin');await p.$executeRawUnsafe('ALTER TABLE remnawave_settings RENAME TO xera_remnawave_settings');})().finally(()=>p.$disconnect()).catch(()=>process.exitCode=1);
JS
ACTION=upgrade-panel; CONTAINER=$new_id; CHANGED=false; DB_CHANGED=false
deploy
# Verify with a protected helper instead of printing test secrets.
docker inspect "$(compose ps --quiet remnawave)" > "$WORK/container.before.json"; database_environment
database_run snapshot > "$WORK/verified.json"
printf 'PASS historic fork upgrade repairs encrypted credentials and legacy table names\n'
# Restore the quiesced legacy backup: the same image repairs it again during startup.
requested=$BACKUP; BACKUP=$requested; STATE="$ROOT/registry/panel.json"; load_state
restore_panel
step 'Restored credentials verified' verify_database
printf 'PASS transactional PostgreSQL restore and application readiness\n'
compose up -d --no-deps remnawave >/dev/null
START_APPS=(remnawave); step 'Start restored test panel' wait_ready
# Standalone backup must not inherit START_APPS from a previous upgrade.
rm -f "$WORK/state.before.json"
START_APPS=(remnawave standby-worker)
backup_current
requested=$BACKUP
python3 - "$requested/state.before.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['runningApplications']==['remnawave']
PY
compose --profile standby up -d --no-deps standby-worker >/dev/null
restore_panel
[[ $(docker inspect --format '{{.State.Running}}' "$(compose ps --all --quiet standby-worker)") == false ]]
printf 'PASS standalone backup/restore preserves an intentionally stopped worker\n'
compose stop "${APPS[@]}" >/dev/null
backup_current
requested=$BACKUP
compose up -d --no-deps remnawave >/dev/null
restore_panel
[[ $(docker inspect --format '{{.State.Running}}' "$(compose ps --all --quiet remnawave)") == false ]]
[[ $(docker inspect --format '{{.State.Running}}' "$(compose ps --all --quiet standby-worker)") == false ]]
printf 'PASS restore of an offline backup keeps all application writers stopped\n'
compose up -d --no-deps remnawave >/dev/null
START_APPS=(remnawave); step 'API ready for migration test' wait_ready
python3 "$installer_dir/tests/marzban-api.py" "$(compose ps --quiet remnawave)" http://127.0.0.1:43873
