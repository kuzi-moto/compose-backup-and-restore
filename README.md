# compose-backup-and-restore

This repo provides a unified script for backing up and restoring Docker Compose projects over SSH, streaming archives back to your local machine to avoid consuming remote disk space.

**Primary script**
- `compose-remote.sh`: Backup and restore remote Compose projects. Supports both `docker compose` and `docker-compose`.

**Backup (remote -> local)**
```
./compose-remote.sh backup-remote --host myserver --dest ./backups
```

**Restore (local -> remote)**
```
./compose-remote.sh restore-remote --host myserver --backup ./backups/myserver/project_20260206_120000.tar.gz --target /srv/project --overwrite
```

**Archive format**
- Stack files are stored under `stack/`.
- Volume data is stored under `volumes/<volume>/`.

**Notes**
- If `--root` is not specified, the script auto-discovers projects using `docker compose ls` (if available), then falls back to a filesystem scan from `/` with safe excludes.
- The remote host must have GNU tar (needs `--transform`).
- Volume selection is based on the Compose project directory name (prefix match `<project>_`).
- Use `--sudo` (default) if Docker volumes require root access.
- Old scripts (`backup-compose.sh`, `restore-compose.sh`) are kept for reference but are superseded by `compose-remote.sh`.
