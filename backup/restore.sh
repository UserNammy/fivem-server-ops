#!/usr/bin/env bash
# Restore a backup produced by backup.sh.
#
# Usage:
#   restore.sh --list [--remote]
#   restore.sh [--remote] [--db-only|--resources-only] [--yes] <backup-name|latest>
#
# Stop the game server first (docker compose stop fxserver): restoring the
# database under a running server corrupts player state.
set -Eeuo pipefail

log() { printf '[restore] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_PREFIX="${BACKUP_PREFIX:-fivem}"
BACKUP_REMOTE="${BACKUP_REMOTE:-}"
RESOURCES_DIR="${RESOURCES_DIR:-/data/server-data/resources}"

DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

FROM_REMOTE=false
DO_DB=true
DO_RESOURCES=true
ASSUME_YES=false
LIST=false
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)         FROM_REMOTE=true ;;
    --db-only)        DO_RESOURCES=false ;;
    --resources-only) DO_DB=false ;;
    --yes|-y)         ASSUME_YES=true ;;
    --list)           LIST=true ;;
    -h|--help)        usage 0 ;;
    -*)               die "unknown option $1" ;;
    *)                TARGET="$1" ;;
  esac
  shift
done

list_backups() {
  if [[ "${FROM_REMOTE}" == true ]]; then
    [[ -n "${BACKUP_REMOTE}" ]] || die "BACKUP_REMOTE is not set"
    rclone lsf --dirs-only "${BACKUP_REMOTE}" | sed 's#/$##' | grep "^${BACKUP_PREFIX}-" | sort
  else
    find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name "${BACKUP_PREFIX}-*" \
      -printf '%f\n' | sort
  fi
}

if [[ "${LIST}" == true ]]; then
  list_backups
  exit 0
fi

[[ -n "${TARGET}" ]] || usage 1

if [[ "${TARGET}" == "latest" ]]; then
  TARGET="$(list_backups | tail -n 1)"
  [[ -n "${TARGET}" ]] || die "no backup found"
fi
[[ "${TARGET}" =~ ^${BACKUP_PREFIX}-[0-9]{8}T[0-9]{6}Z$ ]] || die "invalid backup name: ${TARGET}"

SRC="${BACKUP_DIR}/${TARGET}"
if [[ "${FROM_REMOTE}" == true ]]; then
  log "downloading ${BACKUP_REMOTE}/${TARGET}"
  mkdir -p "${SRC}"
  rclone copy --checksum "${BACKUP_REMOTE}/${TARGET}" "${SRC}"
fi
[[ -d "${SRC}" ]] || die "backup not found: ${SRC}"

log "verifying checksums"
( cd "${SRC}" && sha256sum -c --quiet SHA256SUMS ) || die "checksum verification failed"

if [[ "${ASSUME_YES}" != true ]]; then
  echo "About to restore ${TARGET}:"
  [[ "${DO_DB}" == true ]] && echo "  - database on ${DB_HOST} (existing tables will be overwritten)"
  [[ "${DO_RESOURCES}" == true ]] && echo "  - resources into ${RESOURCES_DIR} (current copy kept aside)"
  read -r -p "Type 'restore' to continue: " answer
  [[ "${answer}" == "restore" ]] || die "aborted"
fi

if [[ "${DO_DB}" == true ]]; then
  [[ -n "${DB_PASSWORD}" ]] || die "DB_PASSWORD (or MARIADB_ROOT_PASSWORD) is not set"
  DEFAULTS_FILE="$(mktemp)"
  trap 'rm -f "${DEFAULTS_FILE}"' EXIT
  chmod 600 "${DEFAULTS_FILE}"
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' \
    "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASSWORD}" > "${DEFAULTS_FILE}"

  log "restoring database"
  # The dump was taken with --databases, so it contains CREATE DATABASE/USE.
  gunzip -c "${SRC}/db.sql.gz" | mariadb --defaults-extra-file="${DEFAULTS_FILE}"
  log "database restored"
fi

if [[ "${DO_RESOURCES}" == true ]]; then
  if [[ -f "${SRC}/resources.tar.gz" ]]; then
    ASIDE="${RESOURCES_DIR%/}.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
    if [[ -d "${RESOURCES_DIR}" ]] && [[ -n "$(ls -A "${RESOURCES_DIR}")" ]]; then
      log "keeping current resources in ${ASIDE}"
      mkdir -p "${ASIDE}"
      find "${RESOURCES_DIR}" -mindepth 1 -maxdepth 1 -exec mv -t "${ASIDE}" {} +
    fi
    mkdir -p "${RESOURCES_DIR}"
    tar -xzf "${SRC}/resources.tar.gz" -C "${RESOURCES_DIR}"
    log "resources restored"
  else
    log "WARNING: no resources.tar.gz in ${TARGET}, skipping"
  fi
fi

log "restore of ${TARGET} complete. Start the server: docker compose start fxserver"
