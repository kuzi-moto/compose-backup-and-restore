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
  - The archive format is <project>/stack/ for stack files and <project>/volumes/<volume>/ for volume data.
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

produce_stream() {
  archive_root="$project_name"

  collect_volumes() {
    {
      # 1) Compose-declared volumes (includes external volumes by explicit name).
      if [ -n "$compose_cmd" ]; then
        (cd "$project_dir" && $compose_cmd -f "$compose_file" config --volumes 2>/dev/null) || true
      fi

      # 2) Volumes currently attached to containers in this compose project.
      $SUDO docker ps -aq --filter "label=com.docker.compose.project=$project_name" | while read -r cid; do
        [ -n "$cid" ] || continue
        $SUDO docker inspect --format "{{range .Mounts}}{{if eq .Type \"volume\"}}{{println .Name}}{{end}}{{end}}" "$cid" 2>/dev/null || true
      done

      # 3) Legacy fallback by project name prefix.
      $SUDO docker volume ls -qf "name=${project_name}_*" || true
    } | awk "NF && !seen[\$0]++"
  }

  # Build a single tar stream containing both stack and volumes.
  docker_args=(run --rm -v "$project_dir:/src/${archive_root}/stack:ro")
  discovered=0
  exported=0
  while read -r volume; do
    [ -n "$volume" ] || continue
    if [ "$include_nfs" = "0" ] && echo "$volume" | grep -q "nfs"; then
      continue
    fi
    if ! $SUDO docker volume inspect "$volume" >/dev/null 2>&1; then
      continue
    fi
    discovered=$((discovered + 1))
    echo "Backing up volume: $volume" >&2
    docker_args+=(--mount "type=volume,src=$volume,dst=/src/${archive_root}/volumes/${volume},readonly")
    exported=$((exported + 1))
  done < <(collect_volumes)

  if [ "$discovered" -eq 0 ]; then
    echo "WARNING: No Docker volumes discovered for project: $project_name" >&2
  fi

  if [ "$discovered" -gt 0 ] && [ "$exported" -eq 0 ]; then
    echo "ERROR: Found $discovered Docker volumes but exported none for project: $project_name" >&2
    exit 3
  fi

  $SUDO docker "${docker_args[@]}" alpine tar -C /src \
    --exclude "*/pgsql_tmp" \
    --exclude "*/pgsql_tmp/*" \
    -cf - "$archive_root"
}

if [ "$pause" = "1" ] && [ -n "$compose_cmd" ]; then
  (cd "$project_dir" && $compose_cmd -f "$compose_file" pause) || true
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

if [ "$pause" = "1" ] && [ -n "$compose_cmd" ]; then
  (cd "$project_dir" && $compose_cmd -f "$compose_file" unpause) || true
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

for d in "$tmpdir"/*; do
  [ -d "$d" ] || continue
  if [ -d "$d/stack" ]; then
    stack_src="$d/stack"
    vol_src="$d/volumes"
    break
  fi
done

if [ -z "$stack_src" ] || [ ! -d "$stack_src" ]; then
  echo "ERROR: Could not find <project>/stack directory in backup archive" >&2
  exit 2
fi

if [ "$stop_stack" = "1" ] && [ -n "$compose_cmd" ] && [ -d "$target_dir" ]; then
  for file in "$target_dir/docker-compose.yml" "$target_dir/docker-compose.yaml" "$target_dir/compose.yml" "$target_dir/compose.yaml"; do
    if [ -f "$file" ]; then
      (cd "$target_dir" && $compose_cmd -f "$file" stop) || true
      break
    fi
  done
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
  done
fi'

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
