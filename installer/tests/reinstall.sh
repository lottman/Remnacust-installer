#!/usr/bin/env bash
set -Eeuo pipefail
installer=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d -t remnacust-reinstall.XXXXXXXX)
trap '[[ $fixture == /tmp/remnacust-reinstall.* ]] && rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/source/panel/backend"
export FIXTURE=$fixture
cat > "$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ ${MOCK_UNAVAILABLE:-false} != true ]] || exit 1
if [[ $* == 'volume ls --quiet' ]]; then cat "$FIXTURE/volumes"; fi
MOCK
chmod +x "$fixture/bin/docker"
export PATH="$fixture/bin:$PATH"
touch "$fixture/source/panel/backend/.env.sample"
prepare() {
    source "$installer/installer.sh"
    ROOT="$fixture/$1/root"; WORK="$fixture/$1/work"; LOG="$fixture/$1/log"
    COMPONENT=panel; ACTION=install-panel; HELPER="$installer/runtime.py"; SOURCE="$fixture/source"
    DOMAIN=panel.example.org; PORT=3000; TLS_METHOD=auto; IMAGE=test-app
    mkdir -p "$ROOT/registry" "$WORK"
    printf 'remnacust-panel_database\nremnacust-panel_caddy-data\n' > "$fixture/volumes"
    python3 - "$ROOT" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);s={'component':'panel','uninstalled':True,'recoverable':False,'directory':str(p/'panel'),'project':'remnacust-panel','composeFiles':[str(p/'panel/compose.json')],'mainService':'remnawave','applications':['remnawave'],'extraServices':['caddy']}
(p/'registry/panel.json').write_text(json.dumps(s))
PY
    port_free() { :; }
}
prepare absent
cp "$ROOT/registry/panel.json" "$fixture/old-registry.json"
assert_fresh_target
select_fresh_target
[[ $PROJECT == remnacust-panel-* && $PROJECT != remnacust-panel ]]
[[ $DIRECTORY == "$ROOT/panel-"* && ! -e $DIRECTORY ]]
cmp "$ROOT/registry/panel.json" "$fixture/old-registry.json"
fresh_files
archive_retired_registry
helper_file_copy "$STATE" "$ROOT/registry/panel.json"
python3 - "$ROOT" "$fixture/old-registry.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);s=json.load(open(p/'registry/panel.json'))
assert not s.get('uninstalled') and s['project']!='remnacust-panel'
c=json.load(open(Path(s['directory'])/'compose.json'))
assert c['name']==s['project'] and all('name' not in v and not v.get('external') for v in c['volumes'].values())
old=list(p.glob('backups/reinstall-*/registry.json'));assert len(old)==1
assert old[0].read_bytes()==Path(sys.argv[2]).read_bytes()
assert old[0].stat().st_mode&0o777==0o600 and old[0].parent.stat().st_mode&0o777==0o700
PY
printf 'PASS v1.2.2 leftover registry permits fresh files with an isolated Docker project and protected history\n'
prepare leftovers
mkdir -p "$ROOT/panel"
printf 'APP_SECRET=retained\n' > "$ROOT/panel/.env"
touch "$ROOT/panel/.remnacust-uninstalled"
assert_fresh_target; select_fresh_target; fresh_files
grep -qx 'APP_SECRET=retained' "$ROOT/panel/.env"
printf 'PASS nonempty old directory is preserved while new files use a separate directory\n'
prepare restored
mkdir -p "$ROOT/panel"; printf 'services: {}\n' > "$ROOT/panel/compose.json"
component_retained panel
if (assert_fresh_target) > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'start --component panel' "$fixture/output"
printf 'PASS restored Compose is offered for recovery even if the old recoverable flag was false\n'
prepare vanished
mkdir -p "$ROOT/panel"
python3 - "$ROOT/registry/panel.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);s=json.loads(p.read_text());s['recoverable']=True;p.write_text(json.dumps(s))
PY
! component_retained panel
assert_fresh_target; select_fresh_target
printf 'PASS stale recoverable=true does not offer a broken restore when Compose disappeared\n'
prepare explicit
PROJECT=remnacust-panel
if (select_fresh_target) > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'Тома проекта' "$fixture/output"
printf 'PASS explicitly reused project with retained volumes is rejected before writing new files\n'
prepare orphan
rm "$ROOT/registry/panel.json"
assert_fresh_target; select_fresh_target
[[ $PROJECT != remnacust-panel ]]
printf 'PASS orphaned default volumes cannot be attached to a new password even without a registry\n'
prepare inactive
python3 - "$ROOT/registry/panel.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);s=json.loads(p.read_text());s['uninstalled']=False;p.write_text(json.dumps(s))
PY
if (assert_fresh_target) > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'Найдена запись установки' "$fixture/output"
printf 'PASS an active or incomplete installation is never treated as safely uninstalled\n'
prepare unavailable
export MOCK_UNAVAILABLE=true
if (select_fresh_target) > "$fixture/output" 2>&1; then exit 1; fi
grep -q 'Docker недоступен' "$fixture/output"
unset MOCK_UNAVAILABLE
printf 'PASS failed volume discovery prevents fresh installation before files change\n'
WORK=''
