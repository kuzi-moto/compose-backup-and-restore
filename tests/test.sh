#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/compose-remote-tests.XXXXXX)
if [ "${KEEP_TEST_WORK:-0}" != 1 ]; then trap 'rm -rf "$work"' EXIT; else echo "test work: $work"; fi
mkdir -p "$work/bin" "$work/project" "$work/volumes/sample_data" "$work/volumes/sample_uploads" "$work/out"
printf 'services:\n  datastore:\n    image: postgres:16\n' > "$work/project/compose.yml"
printf 'TOP_SECRET=do-not-log-this\n' > "$work/project/.env"
printf 'database bytes\n' > "$work/volumes/sample_data/data"
printf 'upload bytes\n' > "$work/volumes/sample_uploads/file"

cat > "$work/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote="${!#}"
exec bash -c "$remote"
EOF

cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${MOCK_SCENARIO:-official}
printf '%s\n' "$*" >> "${MOCK_DOCKER_LOG:-/dev/null}"
if [ "${1:-}" = compose ] || [[ "$0" = *docker-compose ]]; then
  [ "${1:-}" != compose ] || shift
  if [ "${1:-}" = version ]; then exit 0; fi
  while [ "${1:-}" = -p ] || [ "${1:-}" = -f ]; do shift 2; done
  case "${1:-}" in
    config)
      if [ "${2:-}" = --volumes ]; then printf 'sample_data\nsample_uploads\n'; else printf 'datastore\nweb\n'; fi ;;
    stop|down|up) exit 0 ;;
    exec)
      shift
      [ "${1:-}" = -T ] && shift
      service=$1; shift
      joined="$*"
      case "$joined" in
        *pg_isready*) exit 0 ;;
        *pg_restore*) cat >/dev/null; [ "$scenario" != restore_fail ] ;;
        'test -f manage.py') [ "$service" = web ] ;;
        'python manage.py check') printf 'System check identified no issues.\n' ;;
        *) exit 0 ;;
      esac
  esac
  exit 0
fi

case "${1:-}" in
  ps)
    joined="$*"
    if [[ "$joined" == *'project.working_dir'* ]]; then
      printf '%s|%s|sample\n' "$MOCK_PROJECT_DIR" "$MOCK_PROJECT_DIR/compose.yml"
    elif [[ "$joined" == *'-q'* ]]; then
      case "$scenario" in
        no_postgres) printf 'app1\n' ;;
        multiple) printf 'cid1\ncid2\n' ;;
        salvagewatch_shape) printf 'cid1\napp1\napp2\napp3\n' ;;
        *) printf 'cid1\napp1\n' ;;
      esac
    fi ;;
  inspect)
    joined="$*"; cid="${!#}"
    is_pg=0
    case "$cid" in cid1|cid2) is_pg=1;; esac
    if [[ "$joined" == *'Config.Labels'* ]]; then
      if [ "$cid" = cid2 ]; then printf 'analytics\n'; elif [ "$is_pg" = 1 ]; then printf 'datastore\n'; else printf 'web\n'; fi
    elif [[ "$joined" == *'Config.Image'* ]]; then
      if [ "$is_pg" = 1 ]; then
        [ "$scenario" = custom ] && printf 'company/internal-db:latest\n' || printf 'postgres:16\n'
      else printf 'alpine:3\n'; fi
    elif [[ "$joined" == *'Config.Env'* ]]; then
      if [ "$is_pg" = 1 ] || [ "$scenario" = salvagewatch_shape ]; then printf 'POSTGRES_DB=sampledb\nPOSTGRES_USER=sampleuser\nPOSTGRES_PASSWORD=do-not-log-this\n'; fi
    elif [[ "$joined" == *'printf'*'%s|%s'* ]]; then
      if [ "$is_pg" = 1 ]; then
        [ "$scenario" = parent_mount ] && printf 'sample_data|/var/lib/postgresql\n' || printf 'sample_data|/var/lib/postgresql/data\n'
      fi
    elif [[ "$joined" == *'.Mounts'*'.Destination'* ]]; then
      if [ "$is_pg" = 1 ]; then
        [ "$scenario" = parent_mount ] && printf '/var/lib/postgresql\n' || printf '/var/lib/postgresql/data\n'
      else
        printf '/data\n'
      fi
    elif [[ "$joined" == *'.Mounts'* ]]; then
      [ "$is_pg" = 1 ] && printf 'sample_data\n' || printf 'sample_uploads\n'
    fi ;;
  exec)
    cid=$2; shift 2; joined="$*"
    if [[ "$joined" == *'command -v pg_dump'* ]]; then
      case "$cid" in cid1|cid2) exit 0;; app*) [ "$scenario" = salvagewatch_shape ];; *) exit 1;; esac
    elif [[ "$joined" == *'pg_dump --version'* ]]; then printf 'pg_dump (PostgreSQL) 16.4\n'
    elif [[ "$joined" == *'pg_database_size'* ]]; then printf '1024\n'
    elif [[ "$joined" == *'pg_restore --list'* ]]; then
      cat >/dev/null
      [ "$scenario" != validation_fail ]
    elif [[ "$joined" == *'pg_dump --format=custom'* ]]; then
      [ "$scenario" != dump_fail ] || exit 1
      printf 'FAKE_CUSTOM_DUMP\n'
    fi ;;
  volume)
    action=${2:-}
    case "$action" in
      ls) printf 'sample_data\nsample_uploads\n' ;;
      inspect)
        name=${3:-}
        if [[ "$*" == *'--format'* ]]; then mkdir -p "$MOCK_VOLUME_ROOT/$name"; printf '%s/%s\n' "$MOCK_VOLUME_ROOT" "$name"; else [ -d "$MOCK_VOLUME_ROOT/$name" ]; fi ;;
      create) mkdir -p "$MOCK_VOLUME_ROOT/${3:-}"; printf '%s\n' "${3:-}" ;;
      rm) name="${!#}"; rm -rf "$MOCK_VOLUME_ROOT/$name" ;;
    esac ;;
  run)
    if [[ " $* " == *' -i '* ]]; then
      restore_volume=""
      shift
      while [ $# -gt 0 ]; do
        if [ "$1" = -v ]; then
          mapping=$2; shift 2
          if [ "${mapping#*:}" = /dst ]; then restore_volume=${mapping%%:*}; fi
        else
          shift
        fi
      done
      [ -n "$restore_volume" ] || exit 1
      mkdir -p "$MOCK_VOLUME_ROOT/$restore_volume"
      tar -C "$MOCK_VOLUME_ROOT/$restore_volume" -xf -
      exit 0
    fi
    stage=$(mktemp -d /tmp/mock-docker-run.XXXXXX); trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/src"
    shift
    archive_root=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -v)
          mapping=$2; shift 2; src=${mapping%%:*}; rest=${mapping#*:}; dst=${rest%%:*}
          target="$stage$dst"; mkdir -p "$target"; cp -a "$src/." "$target/" ;;
        --mount)
          mapping=$2; shift 2
          name=$(printf '%s' "$mapping" | sed -n 's/.*src=\([^,]*\).*/\1/p')
          dst=$(printf '%s' "$mapping" | sed -n 's/.*dst=\([^,]*\).*/\1/p')
          target="$stage$dst"; mkdir -p "$target"; cp -a "$MOCK_VOLUME_ROOT/$name/." "$target/" ;;
        -cf) archive_root=$3; shift 3 ;;
        *) shift ;;
      esac
    done
    tar -C "$stage/src" -cf - "$archive_root" ;;
esac
EOF
chmod +x "$work/bin/ssh" "$work/bin/docker"
ln -s docker "$work/bin/docker-compose"

export PATH="$work/bin:$PATH"
export MOCK_PROJECT_DIR="$work/project"
export MOCK_VOLUME_ROOT="$work/volumes"
export MOCK_DOCKER_LOG="$work/docker.log"
remote_tmp_before=$(find /tmp -maxdepth 1 -type d -name 'compose_backup.*' | wc -l | tr -d ' ')

passed=0
ok() { passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || { printf '%s\n' "--- $1" >&2; sed -n '1,120p' "$1" >&2; fail "$3"; }; ok "$3"; }

run_backup() {
  local scenario=$1 dir=$2
  mkdir -p "$dir"
  MOCK_SCENARIO=$scenario "$repo/compose-remote.sh" backup-remote --host mock --dest "$dir" --no-ssh-compress 2>"$dir/stderr" >"$dir/stdout"
}

run_backup no_postgres "$work/out/no-pg"
archive=$(find "$work/out/no-pg" -name '*.tar.gz' -type f)
tar -tzf "$archive" > "$work/no-pg.list"
assert_contains "$work/out/no-pg/stderr" 'no PostgreSQL service found' 'project without PostgreSQL uses generic backup'
assert_contains "$work/no-pg.list" 'metadata/manifest.json' 'generic backup includes a v2 manifest'

run_backup official "$work/out/official"
archive=$(find "$work/out/official" -name '*.tar.gz' -type f)
mkdir -p "$work/out/official/extracted"
tar -xzf "$archive" -C "$work/out/official/extracted"
manifest="$work/out/official/extracted/sample/metadata/manifest.json"
python3 -m json.tool "$manifest" >/dev/null || fail 'manifest is valid JSON'; ok 'manifest is valid JSON'
assert_contains "$work/out/official/stderr" 'service=datastore' 'database service need not be named db'
assert_contains "$work/out/official/stderr" 'Logical dump validation succeeded' 'official PostgreSQL image is dumped and validated'
assert_contains "$manifest" '"format_version": 2' 'manifest records format version 2'
assert_contains "$manifest" '"database":"sampledb"' 'manifest records detected database'
assert_contains "$manifest" '"data_volumes":["sample_data"]' 'manifest identifies PostgreSQL data volume'
[ -f "$work/out/official/extracted/sample/databases/datastore.dump.sha256" ] || fail 'dump checksum is present'; ok 'dump checksum is present'
[ -f "${archive}.sha256" ] || fail 'archive checksum is present'; ok 'archive checksum is present'
if grep -R -Fq 'do-not-log-this' "$work/out/official/stdout" "$work/out/official/stderr"; then fail 'password is absent from normal output'; fi; ok 'password is absent from normal output'

run_backup custom "$work/out/custom"
assert_contains "$work/out/custom/stderr" 'PostgreSQL detected' 'custom image is detected from PostgreSQL data mount and tools'

run_backup salvagewatch_shape "$work/out/salvagewatch-shape"
assert_contains "$work/out/salvagewatch-shape/stderr" 'service=datastore' 'application containers with PostgreSQL environment and client tools are not server candidates'

run_backup parent_mount "$work/out/parent-mount"
parent_archive=$(find "$work/out/parent-mount" -name '*.tar.gz' -type f)
mkdir -p "$work/out/parent-mount/extracted"
tar -xzf "$parent_archive" -C "$work/out/parent-mount/extracted"
parent_manifest="$work/out/parent-mount/extracted/sample/metadata/manifest.json"
assert_contains "$parent_manifest" '"data_volumes":["sample_data"]' 'parent PostgreSQL mount is recorded as a database data volume'

if run_backup multiple "$work/out/multiple"; then fail 'multiple PostgreSQL candidates fail safely'; fi
assert_contains "$work/out/multiple/stderr" 'Multiple PostgreSQL containers' 'multiple PostgreSQL candidates fail safely'
[ -z "$(find "$work/out/multiple" -name '*.part' -o -name '*.tar.gz')" ] || fail 'failed candidate detection cleans partial files'; ok 'failed candidate detection cleans partial files'

if run_backup dump_fail "$work/out/dump-fail"; then fail 'failed pg_dump rejects backup'; fi
assert_contains "$work/out/dump-fail/stderr" 'pg_dump failed' 'failed pg_dump rejects backup'
[ -z "$(find "$work/out/dump-fail" -name '*.part' -o -name '*.tar.gz')" ] || fail 'pg_dump failure cleans temporary local files'; ok 'pg_dump failure cleans temporary local files'

if run_backup validation_fail "$work/out/validation-fail"; then fail 'failed validation rejects backup'; fi
assert_contains "$work/out/validation-fail/stderr" 'validation failed' 'failed pg_restore --list rejects backup'
remote_tmp_after=$(find /tmp -maxdepth 1 -type d -name 'compose_backup.*' | wc -l | tr -d ' ')
[ "$remote_tmp_before" = "$remote_tmp_after" ] || fail 'remote temporary directories are cleaned after success and failure'; ok 'remote temporary directories are cleaned after success and failure'

# Restore the version 2 archive through the same mocked SSH and Docker boundary.
printf 'stale database bytes\n' > "$work/volumes/sample_data/stale"
python3 -m json.tool "$manifest" > "$manifest.reformatted"
mv "$manifest.reformatted" "$manifest"
reformatted_archive="$work/reformatted-v2.tar.gz"
tar -C "$work/out/official/extracted" -czf "$reformatted_archive" sample
MOCK_SCENARIO=official "$repo/compose-remote.sh" restore-remote --host mock --backup "$reformatted_archive" --target "$work/restored" --overwrite --no-sudo >"$work/restore.log" 2>&1
assert_contains "$work/restore.log" 'format-version 2 archive with manifest' 'restore parses a reformatted JSON manifest'
assert_contains "$work/restore.log" 'Skipping archived raw PostgreSQL volume sample_data' 'logical restore replaces rather than overlays raw PostgreSQL volume'
assert_contains "$work/restore.log" 'Restored non-database volume: sample_uploads' 'logical restore preserves non-database volumes'
assert_contains "$work/restore.log" 'Logical PostgreSQL restore succeeded' 'new archive performs logical PostgreSQL restore'
assert_contains "$work/docker.log" '-p sample' 'restore pins Compose to the project name recorded in the manifest'
assert_contains "$work/restore.log" 'System check identified no issues' 'detected Django service is verified'

# A failed pg_restore must stop the workflow before any remaining services start.
restore_fail_log="$work/restore-fail.log"
restore_fail_docker_log="$work/restore-fail-docker.log"
if MOCK_SCENARIO=restore_fail MOCK_DOCKER_LOG="$restore_fail_docker_log" \
  "$repo/compose-remote.sh" restore-remote --host mock --backup "$reformatted_archive" \
  --target "$work/restore-fail-target" --overwrite --no-sudo >"$restore_fail_log" 2>&1; then
  fail 'failed pg_restore returns a nonzero restore status'
fi
ok 'failed pg_restore returns a nonzero restore status'
assert_contains "$restore_fail_log" 'ERROR: pg_restore failed' 'failed pg_restore prints a clear error'
if grep -Eq ' up -d$' "$restore_fail_docker_log"; then fail 'failed pg_restore does not start remaining Compose services'; fi
ok 'failed pg_restore does not start remaining Compose services'
if grep -Fq 'Restore complete' "$restore_fail_log"; then fail 'failed pg_restore does not print Restore complete'; fi
ok 'failed pg_restore does not print Restore complete'

# A manifest-free archive follows the legacy restore path.
mkdir -p "$work/legacy/sample/stack" "$work/legacy/sample/volumes/legacy_files"
printf 'services: {}\n' > "$work/legacy/sample/stack/compose.yml"
printf 'legacy\n' > "$work/legacy/sample/volumes/legacy_files/file"
tar -C "$work/legacy" -czf "$work/legacy.tar.gz" sample
MOCK_SCENARIO=no_postgres "$repo/compose-remote.sh" restore-remote --host mock --backup "$work/legacy.tar.gz" --target "$work/legacy-restored" --overwrite --no-sudo >"$work/legacy.log" 2>&1
assert_contains "$work/legacy.log" 'legacy archive without a manifest' 'old archive retains fallback restore behavior'

printf '1..%d\n' "$passed"
