#!/usr/bin/env bash
# Backup container entrypoint.
#   (no args)      -> install crontab from BACKUP_SCHEDULE and run crond in foreground
#   backup         -> run one backup now
#   restore ...    -> run restore.sh with the given arguments
#   anything else  -> exec as-is (debugging)
set -Eeuo pipefail

BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 */6 * * *}"
ENV_FILE=/etc/backup.env

case "${1:-cron}" in
  cron)
    # busybox crond starts jobs with an empty environment: persist the
    # relevant variables (properly quoted by `export -p`) for the job.
    umask 077
    export -p | grep -E '^declare -x (DB_|MARIADB_|BACKUP_|RCLONE_|RESOURCES_DIR|TZ)' > "${ENV_FILE}" || true
    echo "${BACKUP_SCHEDULE} . ${ENV_FILE}; /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1" \
      > /etc/crontabs/root
    echo "[backup] schedule installed: ${BACKUP_SCHEDULE}"
    exec crond -f -l 6
    ;;
  backup)
    shift
    exec /usr/local/bin/backup.sh "$@"
    ;;
  restore)
    shift
    exec /usr/local/bin/restore.sh "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
