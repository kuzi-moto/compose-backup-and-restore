# compose-backup-and-restore

This repo provides a unified script for backing up and restoring Docker Compose projects over SSH, streaming archives back to your local machine to avoid consuming remote disk space.

**Primary script**
- `compose-remote.sh`: Backup and restore remote Compose projects. Supports both `docker compose` and `docker-compose`.

**Backup (remote -> local)**
```
./compose-remote.sh backup-remote --host myserver --dest ./backups
```
Backups default to running projects only, no pause, no sudo, and fast streaming with SSH and remote compression enabled.

**Restore (local -> remote)**
```
./compose-remote.sh restore-remote --host myserver --backup ./backups/myserver/project_20260206_120000.tar.gz --target /srv/project --overwrite
```

**Restore one volume locally (backup -> local host)**
```
./compose-remote.sh restore-local-volume --backup ./backups/myserver/project_20260206_120000.tar.gz --volume project_db_data --overwrite
```

**Archive format**
- Stack files are stored under `<project>/stack/`.
- Volume data is stored under `<project>/volumes/<volume>/`.

**Notes**
- If `--root` is not specified, the script auto-discovers projects using `docker compose ls` (if available), then falls back to a filesystem scan from `/` with safe excludes.
- Live PostgreSQL volume backups exclude `pgsql_tmp` scratch directories so transient temp files do not fail the archive.
- Volume selection is based on the Compose project directory name (prefix match `<project>_`).
- Use `--sudo` if Docker volumes require root access.
- Old scripts (`backup-compose.sh`, `restore-compose.sh`) are kept for reference but are superseded by `compose-remote.sh`.
