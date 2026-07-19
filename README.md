# compose-backup-and-restore

`compose-remote.sh` backs up and restores Docker Compose projects over SSH. It preserves stack files and named Docker volumes, and automatically makes a validated logical backup when a running project contains one PostgreSQL service. Both `docker compose` and `docker-compose` are supported.

## Backup

```bash
./compose-remote.sh backup-remote --host app.example.com --user deploy --dest ./backups
```

The script discovers running Compose projects by default. A PostgreSQL server candidate must contain both `pg_dump` and `pg_restore` and must either use an official `postgres` image or mount PostgreSQL's data directory. `POSTGRES_*` environment variables help select the database and user but never qualify a container by themselves, so application and worker containers with PostgreSQL client tools are ignored. No candidate keeps the generic backup behavior; more than one candidate fails safely instead of guessing. The detected service, container, database, and user are printed, but passwords are not.

For a single candidate, the script runs an online custom-format `pg_dump` with `--no-owner --no-acl`, then validates it with `pg_restore --list`. A failed dump or validation leaves no final archive: the local `.part` file and controlled remote temporary directory are cleaned up. Each dump and completed archive receives a SHA-256 checksum.

New archives have this structure:

```text
<project>/
  stack/                         # Compose project directory, including dotfiles
  volumes/<volume>/              # Named volume snapshots
  databases/<service>.dump       # Validated pg_dump custom archive, when detected
  databases/<service>.dump.sha256
  metadata/manifest.json         # format_version 2 metadata
```

The manifest identifies the project, host, Compose file, volumes, and non-secret PostgreSQL restore metadata. PostgreSQL's raw data volume remains in the archive as a secondary copy so existing volume behavior is retained. A raw data directory copied while PostgreSQL is online is not guaranteed to be transactionally consistent; the validated logical dump is the primary recovery source.

If `--root` is omitted, discovery uses labels on running containers (or `docker compose ls` and a filesystem scan with `--all-projects`). Use `--sudo` where Docker access requires it. NFS-named volumes remain excluded unless `--include-nfs` is supplied.

## Restore

```bash
./compose-remote.sh restore-remote \
  --host app.example.com --user deploy \
  --backup ./backups/app.example.com/salvagewatch_20260718_120000.tar.gz \
  --target /srv/salvagewatch --overwrite
```

For a version 2 archive with a logical dump, `--overwrite` is required because database restoration is destructive. Restore uses the project name recorded in the manifest (`docker compose -p`) even when the target directory has a different name. It stops existing services, restores stack files and non-database volumes, removes the archived raw PostgreSQL data volume and lets Compose recreate it with the configured driver and options, starts only the detected database service, waits with `pg_isready`, and runs `pg_restore --clean --if-exists --no-owner --no-acl`. It verifies readiness again, starts the remaining services, and runs `python manage.py check` when one service can be identified confidently as Django (including a conventional `web` service among several workers). Otherwise it prints a manual check command. Versioned manifests are parsed with `jq` or Python's JSON parser rather than regular expressions.

Archives without a manifest are recognized as the old format and continue through the original stack-and-volume restore path. `restore-local-volume` also remains compatible with both formats:

```bash
./compose-remote.sh restore-local-volume \
  --backup ./backups/app.example.com/project_20260718_120000.tar.gz \
  --volume project_uploads --overwrite
```

## Security and backup strategy

The stack directory is copied in full and may contain `.env` files, passwords, API keys, and other secrets. The manifest and normal console output intentionally exclude credentials, but the archive itself must be protected. Encrypt backups before uploading them to remote storage, restrict local permissions, and test restores regularly. Keeping the only backup on one local computer is not an offsite backup strategy.

## Verification and tests

Inspect a backup with `tar -tzf BACKUP.tar.gz`; extract it and run `pg_restore --list <project>/databases/<service>.dump`. Run the automated mock tests with:

```bash
bash tests/test.sh
```

When Docker is available, run the opt-in real-container integration test with:

```bash
bash tests/integration-postgres.sh
```

It builds a disposable Django application image with PostgreSQL client tools, starts several application/worker containers alongside `postgres:16-alpine`, inserts real rows, backs up with genuine `pg_dump`, destroys the stack and volumes, restores into a differently named directory, and verifies the rows, non-database volume, pinned Compose project, and Django system check. SSH alone is looped back locally. All credentials and data are disposable.

For a manual end-to-end test, create a disposable Compose project using `postgres:16` plus a named non-database volume, insert several sample rows, run `backup-remote`, inspect the manifest and validate the dump, then restore with `--overwrite` to a clean target. Confirm the rows and the non-database volume contents, and separately restore a manifest-free archive. Never use production SalvageWatch credentials or data for this test.

The older `backup-compose.sh` and `restore-compose.sh` scripts are retained for reference; `compose-remote.sh` supersedes them.
