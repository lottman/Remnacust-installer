#!/usr/bin/env bash
# Verify uninstall -> fresh install with real PostgreSQL credentials and retained data.
set -Eeuo pipefail
[[ $EUID == 0 ]] || exec sudo env PATH="$PATH" bash "$0" "$@"
installer=${1:-$(cd "$(dirname "$0")/.." && pwd)/installer.sh}
runtime=$(cd "$(dirname "$0")/.." && pwd)/runtime.py
fixture=$(mktemp -d -t remnacust-reinstall-docker.XXXXXXXX)
token="remnacust-reinstall-test-$(date +%s)-$$"
export REMNACUST_ROOT="$fixture/root" REINSTALL_FIXTURE=$fixture REINSTALL_RUNTIME=$runtime
old_project="$token-old"; old_volume="${old_project}_database"
declare -a ids=() projects=("$old_project")
cleanup_test() {
    local project id volume recorded
    if [[ -f $REMNACUST_ROOT/registry/panel.json ]]; then
        recorded=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("project",""))' "$REMNACUST_ROOT/registry/panel.json")
        [[ $recorded != remnacust-panel-* ]] || projects+=("$recorded")
    fi
    for project in "${projects[@]}"; do
        while read -r id; do [[ -z $id ]] || docker rm --force "$id" >/dev/null 2>&1 || true; done < <(docker ps --all --quiet --no-trunc --filter "label=com.docker.compose.project=$project")
        while read -r volume; do [[ -z $volume ]] || docker volume rm "$volume" >/dev/null 2>&1 || true; done < <(docker volume ls --quiet --filter "label=com.docker.compose.project=$project")
    done
    for id in "${ids[@]}"; do docker rm --force "$id" >/dev/null 2>&1 || true; done
    docker volume rm "$old_volume" >/dev/null 2>&1 || true
    [[ $fixture == /tmp/remnacust-reinstall-docker.* ]] && rm -rf -- "$fixture"
}
trap cleanup_test EXIT
docker image inspect postgres:18.4 >/dev/null 2>&1 || docker pull postgres:18.4 >/dev/null
mkdir -p "$REMNACUST_ROOT/registry" "$fixture/source/panel/backend"
touch "$fixture/source/panel/backend/.env.sample"
printf 'POSTGRES_USER=postgres\nPOSTGRES_DB=postgres\nPOSTGRES_PASSWORD=previous-fixture-password\n' > "$fixture/old.env"
docker volume create --label "com.docker.compose.project=$old_project" "$old_volume" >/dev/null
old_db=$(docker run -d --name "$old_project-db" --env-file "$fixture/old.env" \
    --label "com.docker.compose.project=$old_project" --label com.docker.compose.service=remnawave-db \
    --label io.remnacust.installer-managed=panel --label "com.docker.compose.project.working_dir=$REMNACUST_ROOT/panel" \
    --label "com.docker.compose.project.config_files=$REMNACUST_ROOT/panel/compose.json" \
    -v "$old_volume:/var/lib/postgresql" postgres:18.4)
ids+=("$old_db")
wait_postgres() {
    local count
    for count in {1..60}; do
        if docker exec "$1" pg_isready -U postgres >/dev/null 2>&1; then return; fi
        sleep 1
    done
    return 1
}
wait_postgres "$old_db"
docker exec "$old_db" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE TABLE retained_sentinel (value text); INSERT INTO retained_sentinel VALUES ($$old-database-preserved$$);' >/dev/null
bash "$installer" uninstall-panel --project-name "$old_project" --yes
docker volume inspect "$old_volume" >/dev/null

# Exercise main's install path. Only the app/image/HTTPS checks are replaced;
# generated Compose, registry, secrets, volume ownership and PostgreSQL are real.
cat > "$fixture/install-fixture.sh" <<'TEST'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$1"
prepare_host() { :; }
release_source() {
    SOURCE="$REINSTALL_FIXTURE/source"; HELPER="$REINSTALL_RUNTIME"; TAG=v1.2.3
    COMPONENT_VERSION=1.1.2; IMAGE=app-fixture
}
prepare_image() { :; }
port_free() { :; }
install_cli() { :; }
compose() { docker compose --project-name "$PROJECT" -f "$DEPLOY/compose.json" up -d remnawave-db; }
wait_ready() {
    local db count
    db=$(docker compose --project-name "$PROJECT" -f "$DEPLOY/compose.json" ps --quiet remnawave-db)
    for count in {1..60}; do
        if docker exec "$db" pg_isready -U postgres >/dev/null 2>&1; then break; fi
        sleep 1
    done
    docker exec "$db" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -tAc "SELECT to_regclass('\''public.retained_sentinel'\'') IS NULL"' | grep -qx t
}
main install-panel --yes --domain panel.example.org --proxy existing --version 1.2.3
TEST
bash "$fixture/install-fixture.sh" "$installer"
new_project=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project"])' "$REMNACUST_ROOT/registry/panel.json")
projects+=("$new_project")
[[ $new_project != "$old_project" ]]
docker volume inspect "$old_volume" >/dev/null
printf 'PASS main install path replaces the obsolete registry; new PostgreSQL accepts its new password and has a fresh database\n'

# Mount the retained volume again and prove its original row is still present.
restored=$(docker run -d --name "$token-retained" --env-file "$fixture/old.env" -v "$old_volume:/var/lib/postgresql" postgres:18.4)
ids+=("$restored")
wait_postgres "$restored"
docker exec "$restored" psql -U postgres -d postgres -tAc 'SELECT value FROM retained_sentinel' | grep -qx old-database-preserved
printf 'PASS original PostgreSQL data survives fresh installation in its separate retained volume\n'
