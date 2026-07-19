#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/compose-postgres-integration.XXXXXX)
project="cbar_it_$$"
source_dir="$work/$project"
restore_dir="$work/recovery-target-with-different-name"
fake_bin="$work/bin"
mkdir -p "$source_dir/app" "$fake_bin" "$work/backups"

cleanup() {
  docker compose -p "$project" -f "$source_dir/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  if [ -f "$restore_dir/compose.yml" ]; then
    docker compose -p "$project" -f "$restore_dir/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  docker image rm "${project}_application" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

cat > "$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote="${!#}"
exec bash -c "$remote"
EOF
chmod +x "$fake_bin/ssh"

cat > "$source_dir/compose.yml" <<EOF
services:
  datastore:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: integration_db
      POSTGRES_USER: integration_user
      POSTGRES_PASSWORD: disposable-password
    volumes:
      - db_data:/var/lib/postgresql
  web: &application
    build: ./app
    image: ${project}_application
    environment:
      POSTGRES_DB: integration_db
      POSTGRES_USER: integration_user
      POSTGRES_PASSWORD: disposable-password
    command: ["sleep", "infinity"]
    volumes:
      - uploads:/uploads
  email-worker:
    <<: *application
    volumes: []
  maintenance-worker:
    <<: *application
    volumes: []
  etl-worker:
    <<: *application
    volumes: []
volumes:
  db_data:
  uploads:
EOF

cat > "$source_dir/app/Dockerfile" <<'EOF'
FROM python:3.12-alpine
RUN apk add --no-cache postgresql-client \
    && pip install --no-cache-dir "Django>=5,<6"
WORKDIR /app
COPY . .
EOF

cat > "$source_dir/app/manage.py" <<'EOF'
#!/usr/bin/env python
import os
import sys

if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
EOF

cat > "$source_dir/app/settings.py" <<'EOF'
SECRET_KEY = "disposable-integration-key"
INSTALLED_APPS = []
DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": ":memory:"}}
USE_TZ = True
EOF

echo "Starting disposable PostgreSQL and SalvageWatch-shaped application services"
docker compose -p "$project" -f "$source_dir/compose.yml" up -d --build

ready=0
for _ in $(seq 1 60); do
  if docker compose -p "$project" -f "$source_dir/compose.yml" exec -T datastore \
    pg_isready -U integration_user -d integration_db >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" = 1 ] || { echo "PostgreSQL did not become ready" >&2; exit 1; }

# Ensure every application container really has the client tools that caused the original false positives.
for service in web email-worker maintenance-worker etl-worker; do
  docker compose -p "$project" -f "$source_dir/compose.yml" exec -T "$service" \
    sh -c 'command -v pg_dump >/dev/null && command -v pg_restore >/dev/null'
done

docker compose -p "$project" -f "$source_dir/compose.yml" exec -T datastore \
  psql -U integration_user -d integration_db -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE recovery_samples (id integer PRIMARY KEY, label text NOT NULL);
INSERT INTO recovery_samples VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');
SQL
docker compose -p "$project" -f "$source_dir/compose.yml" exec -T web \
  sh -c 'printf "non-database-volume-data\n" > /uploads/sentinel.txt'

echo "Creating real logical backup"
PATH="$fake_bin:$PATH" "$repo/compose-remote.sh" backup-remote \
  --host local-integration --all-projects --root "$source_dir" \
  --dest "$work/backups" --no-ssh-compress --no-sudo >"$work/backup.log" 2>&1
archive=$(find "$work/backups" -type f -name '*.tar.gz' | head -n 1)
[ -n "$archive" ] && [ -f "$archive" ] || { cat "$work/backup.log"; exit 1; }
grep -Fq "PostgreSQL detected: service=datastore" "$work/backup.log"
if grep -Fq "Multiple PostgreSQL containers" "$work/backup.log"; then
  echo "Application containers were incorrectly detected as PostgreSQL servers" >&2
  exit 1
fi

mkdir -p "$work/extracted"
tar -xzf "$archive" -C "$work/extracted"
manifest="$work/extracted/$project/metadata/manifest.json"
dump="$work/extracted/$project/databases/datastore.dump"
python3 - "$manifest" "$project" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
assert manifest.get("format_version") == 2
assert manifest.get("project") == sys.argv[2]
assert len(manifest.get("database_backups", [])) == 1
assert f"{sys.argv[2]}_db_data" in manifest["database_backups"][0].get("data_volumes", [])
PY
docker compose -p "$project" -f "$source_dir/compose.yml" exec -T datastore pg_restore --list < "$dump" >/dev/null

echo "Destroying source stack and volumes"
docker compose -p "$project" -f "$source_dir/compose.yml" down -v --remove-orphans

echo "Restoring into differently named directory: $restore_dir"
PATH="$fake_bin:$PATH" "$repo/compose-remote.sh" restore-remote \
  --host local-integration --backup "$archive" --target "$restore_dir" \
  --overwrite --no-sudo >"$work/restore.log" 2>&1 || { cat "$work/restore.log"; exit 1; }

rows=$(docker compose -p "$project" -f "$restore_dir/compose.yml" exec -T datastore \
  psql -U integration_user -d integration_db -Atc 'SELECT string_agg(label, '"'"','"'"' ORDER BY id) FROM recovery_samples')
[ "$rows" = "alpha,beta,gamma" ] || { echo "Unexpected restored rows: $rows" >&2; exit 1; }
volume_data=$(docker run --rm -v "${project}_uploads:/data:ro" alpine cat /data/sentinel.txt)
[ "$volume_data" = "non-database-volume-data" ] || { echo "Non-database volume was not restored" >&2; exit 1; }
grep -Fq "System check identified no issues" "$work/restore.log"
grep -Fq "Compose restore project: $project" "$work/restore.log"
grep -Fq "Skipping archived raw PostgreSQL volume ${project}_db_data" "$work/restore.log"

echo "PASS: real PostgreSQL rows, non-database volume, project-pinned restore, and Django check verified"
