#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  compose-remote.sh backup-remote --host HOST [options]
  compose-remote.sh restore-remote --host HOST --backup FILE --target DIR [options]

backup-remote options:
  --host HOST              Remote host (required)
  --user USER              SSH user
  --port PORT              SSH port
  --identity PATH          SSH identity file
  --root PATH              Search root for compose files (repeatable). If omitted, auto-discovery is used.
  --dest DIR               Local destination directory (default: ./backups)
  --pause                  Pause stacks during backup (default)
  --no-pause               Do not pause stacks during backup
  --sudo                   Use sudo for docker/tar on remote (default)
  --no-sudo                Do not use sudo on remote
  --include-nfs            Include volumes with 'nfs' in the name

restore-remote options:
  --host HOST              Remote host (required)
  --user USER              SSH user
  --port PORT              SSH port
  --identity PATH          SSH identity file
  --backup FILE            Local backup archive (required)
  --target DIR             Remote target directory for stack files (required)
  --overwrite              Overwrite existing stack dir and volumes
  --stop                   Stop stack before restore (default)
  --no-stop                Do not stop stack before restore
  --sudo                   Use sudo for docker/tar on remote (default)
  --no-sudo                Do not use sudo on remote

Notes:
  - Archives are streamed from the remote host and compressed locally.
  - The archive format contains stack files under stack/ and volume data under volumes/.
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
  ssh "${ssh_opts[@]}" "$ssh_target" "bash -s -- $quoted_args" <<< "$script"
}

case "$cmd" in
  backup-remote)
    host=""
    dest="$(pwd)/backups"
    pause=1
    use_sudo=1
    include_nfs=0
    roots=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --host) host="$2"; shift 2;;
        --user) ssh_user="$2"; shift 2;;
        --port) ssh_port="$2"; shift 2;;
        --identity) ssh_identity="$2"; shift 2;;
        --root) roots+=("$2"); shift 2;;
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

if [ -z "$roots_raw" ] && [ -n "$compose_cmd" ]; then
  # Try docker compose ls for auto-discovery
  if $compose_cmd ls --format "{{.WorkingDir}}" >/dev/null 2>&1; then
    $compose_cmd ls --format "{{.WorkingDir}}"
  fi
fi | while IFS= read -r wdir; do
  [ -d "$wdir" ] || continue
  for f in "$wdir/docker-compose.yml" "$wdir/docker-compose.yaml" "$wdir/compose.yml" "$wdir/compose.yaml"; do
    if [ -f "$f" ]; then
      printf "%s|%s|%s\n" "$wdir" "$f" "$(basename "$wdir")"
      break
    fi
  done
done | {
  if [ -s /dev/stdin ]; then
    cat
  else
    # Fallback to filesystem scan with safe excludes
    IFS=":" read -r -a roots <<< "$roots_raw"
    if [ ${#roots[@]} -eq 0 ]; then
      roots=("/")
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

    project_lines=$(ssh_run_script "$list_script" "$roots_joined")

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

      echo "Backing up $project_name from $project_dir -> $out_file"

      stream_script='set -euo pipefail
project_dir="$1"
compose_file="$2"
project_name="$3"
pause="$4"
use_sudo="$5"
include_nfs="$6"

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

if ! tar --help 2>/dev/null | grep -q -- "--transform"; then
  echo "ERROR: tar does not support --transform on remote host" >&2
  exit 2
fi

if [ "$pause" = "1" ] && [ -n "$compose_cmd" ]; then
  (cd "$project_dir" && $compose_cmd -f "$compose_file" pause) || true
fi

# Stack files under stack/
tar -C "$project_dir" --transform "s,^,stack/," -cf - .

# Volume data under volumes/<volume>/
$SUDO docker volume ls -qf "name=${project_name}_*" | while read -r volume; do
  if [ "$include_nfs" = "0" ] && echo "$volume" | grep -q "nfs"; then
    continue
  fi
  mountpoint=$($SUDO docker volume inspect "$volume" --format "{{ .Mountpoint }}")
  if [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ]; then
    continue
  fi
  $SUDO tar -C "$mountpoint" --transform "s,^,volumes/${volume}/," -cf - .
done

if [ "$pause" = "1" ] && [ -n "$compose_cmd" ]; then
  (cd "$project_dir" && $compose_cmd -f "$compose_file" unpause) || true
fi'

      ssh_run_script "$stream_script" "$project_dir" "$compose_file" "$project_name" "$pause" "$use_sudo" "$include_nfs" | gzip -c > "$out_file"

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
trap 'rm -rf "$tmpdir"' EXIT

tar -xzf - -C "$tmpdir"

stack_src="$tmpdir/stack"
vol_src="$tmpdir/volumes"

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

    cat "$backup_file" | ssh "${ssh_opts[@]}" "$ssh_target" "$remote_cmd"
    echo "Restore complete"
    ;;

  -h|--help)
    usage
    ;;

  *)
    die "Unknown command: $cmd"
    ;;
esac
