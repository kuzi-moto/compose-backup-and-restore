#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  compose-remote.sh backup-remote --host HOST [options]
  compose-remote.sh restore-remote --host HOST --backup FILE --target DIR [options]
  compose-remote.sh restore-local-volume --backup FILE --volume NAME [options]

backup-remote options:
  --host HOST              Remote host (required)
  --user USER              SSH user
  --port PORT              SSH port
  --identity PATH          SSH identity file
  --ssh-compress           Enable SSH transport compression (-C) (default)
  --no-ssh-compress        Disable SSH transport compression
  --remote-compress        Compress backup stream on remote (pigz/gzip -1) (default)
  --local-compress         Compress backup stream locally instead of on remote
  --fast                   Enable both --ssh-compress and --remote-compress (default)
  --root PATH              Search root for compose files (repeatable). If omitted, auto-discovery is used.
  --running-only           Back up only compose projects with currently running containers (default)
  --all-projects           Back up all discovered compose projects
  --dest DIR               Local destination directory (default: ./backups)
  --pause                  Pause stacks during backup
  --no-pause               Do not pause stacks during backup (default)
  --sudo                   Use sudo for docker/tar on remote
  --no-sudo                Do not use sudo on remote (default)
  --include-nfs            Include volumes with 'nfs' in the name

restore-remote options:
  --host HOST              Remote host (required)
  --user USER              SSH user
  --port PORT              SSH port
  --identity PATH          SSH identity file
  --ssh-compress           Enable SSH transport compression (-C)
  --backup FILE            Local backup archive (required)
  --target DIR             Remote target directory for stack files (required)
  --overwrite              Overwrite existing stack dir and volumes
  --stop                   Stop stack before restore (default)
  --no-stop                Do not stop stack before restore
  --sudo                   Use sudo for docker/tar on remote (default)
  --no-sudo                Do not use sudo on remote

restore-local-volume options:
  --backup FILE            Local backup archive (required)
  --volume NAME            Source volume name inside backup archive (required)
  --target-volume NAME     Local destination Docker volume name (default: same as --volume)
  --overwrite              Overwrite destination volume if it exists
  --sudo                   Use sudo for docker/tar locally (default)
  --no-sudo                Do not use sudo locally

Notes:
  - Archives are streamed from the remote host; compression can be local or remote based on options.
  - New archives also contain <project>/metadata/manifest.json and, when PostgreSQL is detected,
    a validated custom-format dump under <project>/databases/.
  - Compose detection supports docker-compose and docker compose.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

cmd="$1"
shift

ssh_target=""
ssh_opts=()
ssh_user=""
ssh_port=""
ssh_identity=""
ssh_compress=0

set_ssh_target() {
  local host="$1"
  if [ -n "$ssh_user" ]; then
    ssh_target="${ssh_user}@${host}"
  else
    ssh_target="$host"
  fi
}

build_ssh_opts() {
  ssh_opts=()
  if [ -n "$ssh_port" ]; then
    ssh_opts+=("-p" "$ssh_port")
  fi
  if [ -n "$ssh_identity" ]; then
    ssh_opts+=("-i" "$ssh_identity")
  fi
  if [ "$ssh_compress" = "1" ]; then
    ssh_opts+=("-C")
  fi
}

escape_single_quotes() {
  local input="$1"
  printf "%s" "${input//\'/\'\\\'\'}"
}

ssh_run_script() {
  local script="$1"
  shift
  local quoted_args=""
  if [ $# -gt 0 ]; then
    printf -v quoted_args '%q ' "$@"
  fi
  ssh ${ssh_opts[@]+"${ssh_opts[@]}"} "$ssh_target" "bash -s -- $quoted_args" <<< "$script"
}

case "$cmd" in
  backup-remote)
    host=""
    dest="$(pwd)/backups"
    ssh_compress=1
    pause=0
    use_sudo=0
    include_nfs=0
    remote_compress=1
    running_only=1
    roots=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --host) host="$2"; shift 2;;
        --user) ssh_user="$2"; shift 2;;
        --port) ssh_port="$2"; shift 2;;
        --identity) ssh_identity="$2"; shift 2;;
        --ssh-compress) ssh_compress=1; shift;;
        --no-ssh-compress) ssh_compress=0; shift;;
        --remote-compress) remote_compress=1; shift;;
        --local-compress) remote_compress=0; shift;;
        --fast) ssh_compress=1; remote_compress=1; shift;;
        --root) roots+=("$2"); shift 2;;
        --running-only) running_only=1; shift;;
        --all-projects) running_only=0; shift;;
        --dest) dest="$2"; shift 2;;
        --pause) pause=1; shift;;
        --no-pause) pause=0; shift;;
        --sudo) use_sudo=1; shift;;
        --no-sudo) use_sudo=0; shift;;
        --include-nfs) include_nfs=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "Unknown option: $1";;
      esac
    done

    [ -n "$host" ] || die "--host is required"

    set_ssh_target "$host"
    build_ssh_opts

    mkdir -p "$dest"

    roots_joined=""
    if [ ${#roots[@]} -gt 0 ]; then
      roots_joined=$(IFS=:; echo "${roots[*]}")
    fi

list_script='set -euo pipefail
roots_raw="$1"
running_only="$2"
compose_cmd=""
if command -v docker-compose >/dev/null 2>&1; then
  compose_cmd="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  compose_cmd="docker compose"
fi

emit_from_file_list() {
  while IFS= read -r -d "" file; do
    dir=$(dirname "$file")
    name=$(basename "$dir")
    printf "%s|%s|%s\n" "$dir" "$file" "$name"
  done | awk -F"|" "!seen[\$1]++"
}

emit_from_running_containers() {
  docker ps --format "{{.Label \"com.docker.compose.project.working_dir\"}}|{{.Label \"com.docker.compose.project.config_files\"}}|{{.Label \"com.docker.compose.project\"}}" \
    | awk -F"|" "{
        dir=\$1; cfg=\$2; name=\$3
        if (dir == \"\" || name == \"\") next
        split(cfg, arr, \",\")
        file=arr[1]
        gsub(/^ +| +\$/, \"\", file)
        if (file == \"\") file=dir \"/docker-compose.yml\"
        if (!seen[dir]++) printf \"%s|%s|%s\\n\", dir, file, name
      }"
}

if [ "$running_only" = "1" ]; then
  emit_from_running_containers
  exit 0
fi

if [ -z "$roots_raw" ] && [ -n "$compose_cmd" ]; then
  # Try docker compose ls for auto-discovery. Keep real compose project names.
  if $compose_cmd ls --format "{{.Name}}|{{.WorkingDir}}" >/dev/null 2>&1; then
    $compose_cmd ls --format "{{.Name}}|{{.WorkingDir}}"
  fi
fi | while IFS="|" read -r pname wdir; do
  [ -n "$wdir" ] || continue
  [ -d "$wdir" ] || continue
  if [ -z "$pname" ]; then
    pname="$(basename "$wdir")"
  fi
  for f in "$wdir/docker-compose.yml" "$wdir/docker-compose.yaml" "$wdir/compose.yml" "$wdir/compose.yaml"; do
    if [ -f "$f" ]; then
      printf "%s|%s|%s\n" "$wdir" "$f" "$pname"
      break
    fi
  done
done | {
  if [ -s /dev/stdin ]; then
    cat
  else
    # Fallback to filesystem scan with safe excludes
    if [ -n "$roots_raw" ]; then
      IFS=":" read -r -a roots <<< "$roots_raw"
    else
      roots=("$HOME" "/home" "/srv" "/opt" "/etc" "/")
    fi
    find_cmd() {
      find "$1" -xdev -type d \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /var/lib/docker -o -path /var/run \) -prune -o -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" \) -print0 2>/dev/null
    }
    for root in "${roots[@]}"; do
      [ -d "$root" ] || continue
      find_cmd "$root"
    done | emit_from_file_list
  fi
}'

    project_lines=$(ssh_run_script "$list_script" "$roots_joined" "$running_only")

    if [ -z "$project_lines" ]; then
      echo "No compose projects found under: ${roots[*]}"
      exit 0
    fi

    while IFS='|' read -r project_dir compose_file project_name; do
      [ -n "$project_dir" ] || continue

      ts=$(date +"%Y%m%d_%H%M%S")
      out_dir="$dest/$host"
      mkdir -p "$out_dir"
      out_file="$out_dir/${project_name}_${ts}.tar.gz"
      out_tmp="${out_file}.part"

      echo "Backing up $project_name from $project_dir -> $out_file"

      stream_script='set -euo pipefail
project_dir="$1"
compose_file="$2"
project_name="$3"
pause="$4"
use_sudo="$5"
include_nfs="$6"
remote_compress="$7"

SUDO=""
if [ "$use_sudo" = "1" ]; then
  SUDO="sudo"
fi

compose_cmd=""
if command -v docker-compose >/dev/null 2>&1; then
  compose_cmd="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  compose_cmd="docker compose"
fi

tmpdir=$(mktemp -d /tmp/compose_backup.XXXXXX)
paused=0
cleanup() {
  status=$?
  if [ "$paused" = "1" ] && [ -n "$compose_cmd" ]; then
    (cd "$project_dir" && $compose_cmd -f "$compose_file" unpause) >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=$(printf "%s" "$value" | tr "\r\n\t" "   ")
  printf "%s" "$value"
}

env_value() {
  local cid="$1" key="$2"
  $SUDO docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" "$cid" \
    | sed -n "s/^${key}=//p" | head -n 1
}

detect_postgres() {
  pg_candidates=()
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    service=$($SUDO docker inspect --format "{{index .Config.Labels \"com.docker.compose.service\"}}" "$cid")
    image=$($SUDO docker inspect --format "{{.Config.Image}}" "$cid")
    env_signal=0
    if $SUDO docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" "$cid" | grep -Eq "^POSTGRES_(DB|USER|PASSWORD|HOST_AUTH_METHOD)="; then
      env_signal=1
    fi
    tools_signal=0
    if $SUDO docker exec "$cid" sh -c "command -v pg_dump >/dev/null && command -v pg_restore >/dev/null" >/dev/null 2>&1; then
      tools_signal=1
    fi
    data_signal=0
    if $SUDO docker inspect --format "{{range .Mounts}}{{println .Destination}}{{end}}" "$cid" | grep -Eq "^(/var/lib/postgresql/data|/var/lib/postgresql)(/|$)"; then
      data_signal=1
    fi
    official_signal=0
    case "$image" in
      postgres|postgres:*|postgres@*|docker.io/postgres*|docker.io/library/postgres*|library/postgres*) official_signal=1 ;;
    esac
    if [ "$official_signal" = "1" ] || [ "$env_signal" = "1" ] || { [ "$tools_signal" = "1" ] && [ "$data_signal" = "1" ]; }; then
      if [ "$tools_signal" != "1" ]; then
        echo "ERROR: PostgreSQL candidate service $service ($cid) does not provide both pg_dump and pg_restore" >&2
        exit 4
      fi
      pg_candidates+=("$cid")
    fi
  done < <($SUDO docker ps -q --filter "label=com.docker.compose.project=$project_name")

  if [ "${#pg_candidates[@]}" -gt 1 ]; then
    echo "ERROR: Multiple PostgreSQL containers were detected for project $project_name; refusing to guess:" >&2
    for cid in ${pg_candidates[@]+"${pg_candidates[@]}"}; do
      service=$($SUDO docker inspect --format "{{index .Config.Labels \"com.docker.compose.service\"}}" "$cid")
      echo "  service=$service container=$cid" >&2
    done
    exit 4
  fi
}

collect_volumes() {
  {
    # Compose-declared volumes, attached volumes, and the legacy project-prefix fallback.
    if [ -n "$compose_cmd" ]; then
      (cd "$project_dir" && $compose_cmd -f "$compose_file" config --volumes 2>/dev/null) || true
    fi
    $SUDO docker ps -aq --filter "label=com.docker.compose.project=$project_name" | while read -r cid; do
      [ -n "$cid" ] || continue
      $SUDO docker inspect --format "{{range .Mounts}}{{if eq .Type \"volume\"}}{{println .Name}}{{end}}{{end}}" "$cid" 2>/dev/null || true
    done
    $SUDO docker volume ls -qf "name=${project_name}_*" || true
  } | awk "NF && !seen[\$0]++"
}

archive_root="$project_name"
mkdir -p "$tmpdir/databases" "$tmpdir/metadata"
detect_postgres
pg_service=""
pg_container=""
pg_database=""
pg_user=""
pg_version=""
pg_data_volumes=()

if [ "${#pg_candidates[@]}" -eq 0 ]; then
  echo "PostgreSQL detection: no PostgreSQL service found; using generic Compose backup" >&2
else
  pg_container="${pg_candidates[0]}"
  pg_service=$($SUDO docker inspect --format "{{index .Config.Labels \"com.docker.compose.service\"}}" "$pg_container")
  pg_user=$(env_value "$pg_container" POSTGRES_USER)
  [ -n "$pg_user" ] || pg_user="postgres"
  pg_database=$(env_value "$pg_container" POSTGRES_DB)
  [ -n "$pg_database" ] || pg_database="$pg_user"
  pg_data_dir=$(env_value "$pg_container" PGDATA)
  [ -n "$pg_data_dir" ] || pg_data_dir="/var/lib/postgresql/data"
  pg_version=$($SUDO docker exec "$pg_container" pg_dump --version | sed -E "s/.* ([0-9]+(\.[0-9]+)?).*/\1/")
  while IFS="|" read -r source destination; do
    [ -n "$source" ] || continue
    case "$destination/" in
      "$pg_data_dir/"*|/var/lib/postgresql/data/*) pg_data_volumes+=("$source") ;;
    esac
  done < <($SUDO docker inspect --format "{{range .Mounts}}{{if eq .Type \"volume\"}}{{printf \"%s|%s\\n\" .Name .Destination}}{{end}}{{end}}" "$pg_container")
  echo "PostgreSQL detected: service=$pg_service container=$pg_container database=$pg_database user=$pg_user" >&2
  echo "Creating online PostgreSQL logical dump (custom format)" >&2
  dump_file="$tmpdir/databases/${pg_service}.dump"
  estimated_bytes=$($SUDO docker exec "$pg_container" sh -c '\''if [ -n "${POSTGRES_PASSWORD:-}" ]; then export PGPASSWORD="$POSTGRES_PASSWORD"; fi; exec psql --username "$1" --dbname "$2" --tuples-only --no-align --command "SELECT pg_database_size(current_database())"'\'' sh "$pg_user" "$pg_database" 2>/dev/null || true)
  available_kb=$(df -Pk "$tmpdir" | awk "NR==2 {print \$4}")
  if echo "$estimated_bytes" | grep -Eq "^[0-9]+$"; then
    estimated_kb=$(( (estimated_bytes + 1023) / 1024 ))
    echo "Temporary-space check: database_size=${estimated_kb} KiB available=${available_kb} KiB" >&2
    if [ "$available_kb" -le "$estimated_kb" ]; then
      echo "ERROR: Insufficient temporary disk space for a safe logical dump estimate" >&2
      exit 5
    fi
  else
    echo "WARNING: Could not estimate database size; continuing with temporary-space cleanup protection" >&2
  fi
  # The password, when needed, stays inside the container environment and never appears in argv or output.
  if ! $SUDO docker exec "$pg_container" sh -c '\''if [ -n "${POSTGRES_PASSWORD:-}" ]; then export PGPASSWORD="$POSTGRES_PASSWORD"; fi; exec pg_dump --format=custom --no-owner --no-acl --username "$1" --dbname "$2"'\'' sh "$pg_user" "$pg_database" > "$dump_file"; then
    echo "ERROR: pg_dump failed for service $pg_service database $pg_database" >&2
    exit 5
  fi
  [ -s "$dump_file" ] || { echo "ERROR: pg_dump produced an empty dump" >&2; exit 5; }
  if ! $SUDO docker exec -i "$pg_container" pg_restore --list < "$dump_file" >/dev/null; then
    echo "ERROR: pg_restore --list validation failed for service $pg_service" >&2
    exit 6
  fi
  echo "Logical dump validation succeeded: databases/${pg_service}.dump" >&2
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmpdir/databases" && sha256sum "${pg_service}.dump" > "${pg_service}.dump.sha256")
  else
    (cd "$tmpdir/databases" && shasum -a 256 "${pg_service}.dump" > "${pg_service}.dump.sha256")
  fi
fi

volumes=()
while IFS= read -r volume; do
  [ -n "$volume" ] || continue
  if [ "$include_nfs" = "0" ] && echo "$volume" | grep -q "nfs"; then continue; fi
  if $SUDO docker volume inspect "$volume" >/dev/null 2>&1; then volumes+=("$volume"); fi
done < <(collect_volumes)

volumes_json=""
for volume in "${volumes[@]}"; do
  [ -z "$volumes_json" ] || volumes_json+=","
  volumes_json+="\"$(json_escape "$volume")\""
done
data_volumes_json=""
for volume in ${pg_data_volumes[@]+"${pg_data_volumes[@]}"}; do
  [ -z "$data_volumes_json" ] || data_volumes_json+=","
  data_volumes_json+="\"$(json_escape "$volume")\""
done
database_json=""
if [ -n "$pg_service" ]; then
  database_json="{\"service\":\"$(json_escape "$pg_service")\",\"engine\":\"postgresql\",\"database\":\"$(json_escape "$pg_database")\",\"user\":\"$(json_escape "$pg_user")\",\"format\":\"pg_dump_custom\",\"file\":\"databases/$(json_escape "$pg_service").dump\",\"validated\":true,\"postgres_version\":\"$(json_escape "$pg_version")\",\"data_volumes\":[${data_volumes_json}]}"
fi
created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
remote_hostname=$(hostname)
printf "{\n  \"format_version\": 2,\n  \"project\": \"%s\",\n  \"created_at\": \"%s\",\n  \"hostname\": \"%s\",\n  \"compose_file\": \"%s\",\n  \"database_backups\": [%s],\n  \"volumes\": [%s]\n}\n" \
  "$(json_escape "$project_name")" "$created_at" "$(json_escape "$remote_hostname")" "$(json_escape "$(basename "$compose_file")")" "$database_json" "$volumes_json" \
  > "$tmpdir/metadata/manifest.json"
echo "Created format-version 2 manifest" >&2

produce_stream() {

  docker_args=(run --rm -v "$project_dir:/src/${archive_root}/stack:ro" \
    -v "$tmpdir/databases:/src/${archive_root}/databases:ro" \
    -v "$tmpdir/metadata:/src/${archive_root}/metadata:ro")
  for volume in ${volumes[@]+"${volumes[@]}"}; do
    echo "Backing up volume: $volume" >&2
    docker_args+=(--mount "type=volume,src=$volume,dst=/src/${archive_root}/volumes/${volume},readonly")
  done
  if [ "${#volumes[@]}" -eq 0 ]; then
    echo "WARNING: No Docker volumes discovered for project: $project_name" >&2
  fi
  if [ -n "$pg_service" ] && [ "${#pg_data_volumes[@]}" -gt 0 ]; then
    echo "WARNING: Raw PostgreSQL volume data is a secondary copy and may not be transactionally consistent; use the logical dump for recovery" >&2
  fi
  $SUDO docker "${docker_args[@]}" alpine tar -C /src \
    --exclude "*/pgsql_tmp" \
    --exclude "*/pgsql_tmp/*" \
    -cf - "$archive_root"
}

if [ "$pause" = "1" ] && [ -n "$compose_cmd" ]; then
  (cd "$project_dir" && $compose_cmd -f "$compose_file" pause)
  paused=1
fi

if [ "$remote_compress" = "1" ]; then
  if command -v pigz >/dev/null 2>&1; then
    produce_stream | pigz -1 -c
  else
    produce_stream | gzip -1 -c
  fi
else
  produce_stream
fi

if [ "$paused" = "1" ]; then
  (cd "$project_dir" && $compose_cmd -f "$compose_file" unpause)
  paused=0
fi'

      if [ "$remote_compress" = "1" ]; then
        if ssh_run_script "$stream_script" "$project_dir" "$compose_file" "$project_name" "$pause" "$use_sudo" "$include_nfs" "$remote_compress" > "$out_tmp"; then
          mv -f "$out_tmp" "$out_file"
        else
          rm -f "$out_tmp"
          die "Backup failed for project: $project_name"
        fi
      elif ssh_run_script "$stream_script" "$project_dir" "$compose_file" "$project_name" "$pause" "$use_sudo" "$include_nfs" "$remote_compress" | gzip -c > "$out_tmp"; then
        mv -f "$out_tmp" "$out_file"
      else
        rm -f "$out_tmp"
        die "Backup failed for project: $project_name"
      fi

      echo "Saved: $out_file"
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$out_file" > "${out_file}.sha256"
      else
        shasum -a 256 "$out_file" > "${out_file}.sha256"
      fi
      echo "SHA-256: ${out_file}.sha256"
    done <<< "$project_lines"
    ;;

  restore-remote)
    host=""
    backup_file=""
    target_dir=""
    overwrite=0
    stop_stack=1
    use_sudo=1

    while [ $# -gt 0 ]; do
      case "$1" in
        --host) host="$2"; shift 2;;
        --user) ssh_user="$2"; shift 2;;
        --port) ssh_port="$2"; shift 2;;
        --identity) ssh_identity="$2"; shift 2;;
        --ssh-compress) ssh_compress=1; shift;;
        --backup) backup_file="$2"; shift 2;;
        --target) target_dir="$2"; shift 2;;
        --overwrite) overwrite=1; shift;;
        --stop) stop_stack=1; shift;;
        --no-stop) stop_stack=0; shift;;
        --sudo) use_sudo=1; shift;;
        --no-sudo) use_sudo=0; shift;;
        -h|--help) usage; exit 0;;
        *) die "Unknown option: $1";;
      esac
    done

    [ -n "$host" ] || die "--host is required"
    [ -n "$backup_file" ] || die "--backup is required"
    [ -f "$backup_file" ] || die "Backup file not found: $backup_file"
    [ -n "$target_dir" ] || die "--target is required"

    set_ssh_target "$host"
    build_ssh_opts

    restore_script='set -euo pipefail
target_dir="$1"
overwrite="$2"
stop_stack="$3"
use_sudo="$4"

SUDO=""
if [ "$use_sudo" = "1" ]; then
  SUDO="sudo"
fi

compose_cmd=""
if command -v docker-compose >/dev/null 2>&1; then
  compose_cmd="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  compose_cmd="docker compose"
fi

tmpdir=$(mktemp -d /tmp/compose_restore.XXXXXX)
trap "rm -rf \"$tmpdir\"" EXIT

if tar --help 2>/dev/null | grep -q "read_concatenated_archives"; then
  # bsdtar (macOS): this option makes extraction continue across concatenated tar streams.
  tar -xzf - -C "$tmpdir" --options read_concatenated_archives
else
  # GNU tar: continue reading after end-of-archive markers.
  tar -xzf - -C "$tmpdir" --ignore-zeros
fi

stack_src=""
vol_src=""
archive_root=""

for d in "$tmpdir"/*; do
  [ -d "$d" ] || continue
  if [ -d "$d/stack" ]; then
    stack_src="$d/stack"
    vol_src="$d/volumes"
    archive_root="$d"
    break
  fi
done

if [ -z "$stack_src" ] || [ ! -d "$stack_src" ]; then
  echo "ERROR: Could not find <project>/stack directory in backup archive" >&2
  exit 2
fi

manifest="$archive_root/metadata/manifest.json"
logical_restore=0
pg_service=""
pg_database=""
pg_user=""
pg_dump_file=""
pg_data_volumes=()

if [ -f "$manifest" ]; then
  format_version=$(sed -n "s/.*\"format_version\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$manifest" | head -n 1)
  [ "$format_version" = "2" ] || { echo "ERROR: Unsupported manifest format version: ${format_version:-unknown}" >&2; exit 2; }
  echo "Restore source: format-version 2 archive with manifest"
  if grep -q "\"engine\":\"postgresql\"" "$manifest"; then
    logical_restore=1
    pg_service=$(sed -n "s/.*\"service\":\"\([^\"]*\)\".*/\1/p" "$manifest" | head -n 1)
    pg_database=$(sed -n "s/.*\"database\":\"\([^\"]*\)\".*/\1/p" "$manifest" | head -n 1)
    pg_user=$(sed -n "s/.*\"user\":\"\([^\"]*\)\".*/\1/p" "$manifest" | head -n 1)
    pg_dump_rel=$(sed -n "s/.*\"file\":\"\([^\"]*\)\".*/\1/p" "$manifest" | head -n 1)
    data_volume_list=$(sed -n "s/.*\"data_volumes\":\[\([^]]*\)\].*/\1/p" "$manifest" | head -n 1)
    while IFS= read -r volume; do [ -n "$volume" ] && pg_data_volumes+=("$volume"); done < <(printf "%s\n" "$data_volume_list" | tr "," "\n" | tr -d "\" ")
    echo "PostgreSQL data volumes selected for clean replacement: ${pg_data_volumes[*]:-(none)}"
    case "$pg_dump_rel" in databases/*.dump) ;; *) echo "ERROR: Unsafe PostgreSQL dump path in manifest" >&2; exit 2;; esac
    pg_dump_file="$archive_root/$pg_dump_rel"
    [ -n "$pg_service" ] && [ -n "$pg_database" ] && [ -n "$pg_user" ] && [ -f "$pg_dump_file" ] || { echo "ERROR: PostgreSQL manifest entry is incomplete or dump is missing" >&2; exit 2; }
    dump_checksum="$pg_dump_file.sha256"
    [ -f "$dump_checksum" ] || { echo "ERROR: Logical dump checksum is missing" >&2; exit 2; }
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$(dirname "$pg_dump_file")" && sha256sum -c "$(basename "$dump_checksum")") >/dev/null
    else
      (cd "$(dirname "$pg_dump_file")" && shasum -a 256 -c "$(basename "$dump_checksum")") >/dev/null
    fi || { echo "ERROR: Logical dump SHA-256 validation failed" >&2; exit 2; }
    echo "Logical dump SHA-256 validation succeeded"
    if [ "$overwrite" != "1" ]; then
      echo "ERROR: A logical PostgreSQL restore is destructive; use --overwrite to confirm replacement" >&2
      exit 2
    fi
  fi
else
  echo "Restore source: legacy archive without a manifest; restoring stack files and volumes"
fi

old_compose_file=""
if [ -n "$compose_cmd" ] && [ -d "$target_dir" ]; then
  for file in "$target_dir/docker-compose.yml" "$target_dir/docker-compose.yaml" "$target_dir/compose.yml" "$target_dir/compose.yaml"; do
    if [ -f "$file" ]; then
      old_compose_file="$file"
      break
    fi
  done
fi
if [ -n "$old_compose_file" ] && { [ "$stop_stack" = "1" ] || [ "$logical_restore" = "1" ]; }; then
  [ "$logical_restore" != "1" ] || echo "Stopping existing services before destructive PostgreSQL restoration"
  if [ "$logical_restore" = "1" ]; then
    # Removing stopped containers releases named volumes so they can be recreated cleanly.
    (cd "$target_dir" && $compose_cmd -f "$old_compose_file" down) || true
  else
    (cd "$target_dir" && $compose_cmd -f "$old_compose_file" stop) || true
  fi
fi

if [ -d "$stack_src" ]; then
  if [ "$overwrite" = "1" ]; then
    rm -rf "$target_dir"
  fi
  mkdir -p "$target_dir"
  cp -a "$stack_src/." "$target_dir/"
fi

if [ -d "$vol_src" ]; then
  for volume_dir in "$vol_src"/*; do
    [ -d "$volume_dir" ] || continue
    volume_name=$(basename "$volume_dir")

    skip_volume=0
    if [ "$logical_restore" = "1" ]; then
      for pg_volume in ${pg_data_volumes[@]+"${pg_data_volumes[@]}"}; do
        if [ "$volume_name" = "$pg_volume" ]; then skip_volume=1; break; fi
      done
    fi
    if [ "$skip_volume" = "1" ]; then
      echo "Skipping archived raw PostgreSQL volume $volume_name; recreating it cleanly for logical restore"
      if $SUDO docker volume inspect "$volume_name" >/dev/null 2>&1; then
        $SUDO docker volume rm -f "$volume_name" >/dev/null
      fi
      $SUDO docker volume create "$volume_name" >/dev/null
      continue
    fi

    if $SUDO docker volume inspect "$volume_name" >/dev/null 2>&1; then
      if [ "$overwrite" = "1" ]; then
        $SUDO docker volume rm -f "$volume_name" >/dev/null 2>&1 || true
      else
        echo "Skipping existing volume: $volume_name"
        continue
      fi
    fi

    $SUDO docker volume create "$volume_name" >/dev/null
    mountpoint=$($SUDO docker volume inspect "$volume_name" --format "{{ .Mountpoint }}")
    [ -n "$mountpoint" ] || continue
    $SUDO tar -C "$volume_dir" -cf - . | $SUDO tar -C "$mountpoint" -xf -
    echo "Restored non-database volume: $volume_name"
  done
fi

if [ "$logical_restore" = "1" ]; then
  [ -n "$compose_cmd" ] || { echo "ERROR: Docker Compose is required for logical PostgreSQL restore" >&2; exit 7; }
  compose_file=""
  for file in "$target_dir/docker-compose.yml" "$target_dir/docker-compose.yaml" "$target_dir/compose.yml" "$target_dir/compose.yaml"; do
    if [ -f "$file" ]; then compose_file="$file"; break; fi
  done
  [ -n "$compose_file" ] || { echo "ERROR: No Compose file found in restored stack" >&2; exit 7; }
  echo "Starting only PostgreSQL service: $pg_service"
  (cd "$target_dir" && $compose_cmd -f "$compose_file" up -d "$pg_service")
  ready=0
  for attempt in $(seq 1 60); do
    if (cd "$target_dir" && $compose_cmd -f "$compose_file" exec -T "$pg_service" pg_isready -U "$pg_user" -d "$pg_database") >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  [ "$ready" = "1" ] || { echo "ERROR: PostgreSQL did not become ready within 120 seconds" >&2; exit 8; }
  echo "PostgreSQL is accepting connections; restoring logical dump"
  if ! (cd "$target_dir" && $compose_cmd -f "$compose_file" exec -T "$pg_service" sh -c "if [ -n \"\${POSTGRES_PASSWORD:-}\" ]; then export PGPASSWORD=\"\$POSTGRES_PASSWORD\"; fi; exec pg_restore --clean --if-exists --no-owner --no-acl --username \"\$1\" --dbname \"\$2\"" sh "$pg_user" "$pg_database") < "$pg_dump_file"; then
    echo "ERROR: pg_restore failed for service $pg_service database $pg_database" >&2
    exit 9
  fi
  if ! (cd "$target_dir" && $compose_cmd -f "$compose_file" exec -T "$pg_service" pg_isready -U "$pg_user" -d "$pg_database") >/dev/null; then
    echo "ERROR: PostgreSQL stopped accepting connections after restore" >&2
    exit 9
  fi
  echo "Logical PostgreSQL restore succeeded: service=$pg_service database=$pg_database user=$pg_user"
  echo "Starting remaining Compose services"
  (cd "$target_dir" && $compose_cmd -f "$compose_file" up -d)

  django_candidates=()
  while IFS= read -r service; do
    [ -n "$service" ] || continue
    [ "$service" = "$pg_service" ] && continue
    if (cd "$target_dir" && $compose_cmd -f "$compose_file" exec -T "$service" test -f manage.py) >/dev/null 2>&1; then
      django_candidates+=("$service")
    fi
  done < <(cd "$target_dir" && $compose_cmd -f "$compose_file" config --services)
  if [ "${#django_candidates[@]}" -eq 1 ]; then
    django_service="${django_candidates[0]}"
    echo "Running Django verification through service: $django_service"
    (cd "$target_dir" && $compose_cmd -f "$compose_file" exec -T "$django_service" python manage.py check)
  elif [ "${#django_candidates[@]}" -gt 1 ]; then
    echo "Multiple services contain manage.py; run the appropriate service manually: $compose_cmd -f $compose_file exec -T SERVICE python manage.py check"
  else
    echo "No Django service was detected confidently. If applicable, verify manually with: $compose_cmd -f $compose_file exec -T SERVICE python manage.py check"
  fi
fi

echo "Restore summary: stack files restored; non-database volumes preserved; logical_postgresql=$logical_restore"'

    echo "Restoring to $host:$target_dir from $backup_file"
    restore_escaped=$(escape_single_quotes "$restore_script")
    remote_cmd="bash -c '$restore_escaped' -- $(printf '%q ' "$target_dir" "$overwrite" "$stop_stack" "$use_sudo")"

    cat "$backup_file" | ssh ${ssh_opts[@]+"${ssh_opts[@]}"} "$ssh_target" "$remote_cmd"
    echo "Restore complete"
    ;;

  restore-local-volume)
    backup_file=""
    source_volume=""
    target_volume=""
    overwrite=0
    use_sudo=1

    while [ $# -gt 0 ]; do
      case "$1" in
        --backup) backup_file="$2"; shift 2;;
        --volume) source_volume="$2"; shift 2;;
        --target-volume) target_volume="$2"; shift 2;;
        --overwrite) overwrite=1; shift;;
        --sudo) use_sudo=1; shift;;
        --no-sudo) use_sudo=0; shift;;
        -h|--help) usage; exit 0;;
        *) die "Unknown option: $1";;
      esac
    done

    [ -n "$backup_file" ] || die "--backup is required"
    [ -f "$backup_file" ] || die "Backup file not found: $backup_file"
    [ -n "$source_volume" ] || die "--volume is required"
    if [ -z "$target_volume" ]; then
      target_volume="$source_volume"
    fi

    SUDO=""
    if [ "$use_sudo" = "1" ]; then
      SUDO="sudo"
    fi

    tmpdir=$(mktemp -d /tmp/compose_restore_local.XXXXXX)
    trap 'rm -rf "$tmpdir"' EXIT

    if tar --help 2>/dev/null | grep -q "read_concatenated_archives"; then
      tar -xzf "$backup_file" -C "$tmpdir" --options read_concatenated_archives
    else
      tar -xzf "$backup_file" -C "$tmpdir" --ignore-zeros
    fi

    volume_src=""
    for d in "$tmpdir"/*; do
      [ -d "$d" ] || continue
      if [ -d "$d/volumes/$source_volume" ]; then
        volume_src="$d/volumes/$source_volume"
        break
      fi
    done

    [ -n "$volume_src" ] || die "Volume '$source_volume' not found in backup archive"

    if $SUDO docker volume inspect "$target_volume" >/dev/null 2>&1; then
      if [ "$overwrite" = "1" ]; then
        $SUDO docker volume rm -f "$target_volume" >/dev/null 2>&1 || true
      else
        die "Target volume '$target_volume' already exists. Use --overwrite to replace it."
      fi
    fi

    $SUDO docker volume create "$target_volume" >/dev/null
    # Restore through a helper container so this works on Docker Desktop
    # (where /var/lib/docker/volumes is inside the VM) and native Linux.
    $SUDO tar -C "$volume_src" -cf - . \
      | $SUDO docker run --rm -i -v "$target_volume:/dst" alpine tar -C /dst -xf -

    echo "Restored volume '$source_volume' from $backup_file into local Docker volume '$target_volume'"
    ;;

  -h|--help)
    usage
    ;;

  *)
    die "Unknown command: $cmd"
    ;;
esac
