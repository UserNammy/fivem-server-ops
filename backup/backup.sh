#!/usr/bin/env bash
# Create a consistent backup of the FiveM stack:
#   - MariaDB logical dump (mariadb-dump --single-transaction, gzip)
#   - resources/ archive (tar.gz, cache excluded)
#   - SHA256SUMS + manifest
# then upload it to S3-compatible storage with rclone and apply retention.
#
# Layout produced:  ${BACKUP_DIR}/fivem-<UTC timestamp>/
#                     db.sql.gz  resources.tar.gz  SHA256SUMS  manifest.txt
set -Eeuo pipefail

log() { printf '[backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; ping_monitor fail; exit 1; }

# ---- configuration (env) ----------------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_PREFIX="${BACKUP_PREFIX:-fivem}"
BACKUP_KEEP_LOCAL="${BACKUP_KEEP_LOCAL:-8}"
BACKUP_KEEP_REMOTE_DAYS="${BACKUP_KEEP_REMOTE_DAYS:-30}"
BACKUP_REMOTE="${BACKUP_REMOTE:-}"           # e.g. s3backup:bucket/prod (empty = local only)
BACKUP_PING_URL="${BACKUP_PING_URL:-}"       # optional dead man's switch (healthchecks.io style)
RESOURCES_DIR="${RESOURCES_DIR:-/data/server-data/resources}"

DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-${MARIADB_DATABASE:-fivem}}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"

ping_monitor() {
  [[ -n "${BACKUP_PING_URL}" ]] || return 0
  local suffix=""
  [[ "${1:-}" == "fail" ]] && suffix="/fail"
  curl -fsS -m 10 --retry 2 -o /dev/null "${BACKUP_PING_URL}${suffix}" || true
}

cleanup() {
  if [[ -n "${DEFAULTS_FILE:-}" ]]; then rm -f "${DEFAULTS_FILE}"; fi
  # A half-written backup must never look like a valid one.
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then rm -rf "${WORK_DIR}"; fi
}
trap cleanup EXIT
trap 'die "failed at line ${LINENO}"' ERR

# ---- single instance lock ---------------------------------------------------
mkdir -p "${BACKUP_DIR}"
exec 9>"${BACKUP_DIR}/.backup.lock"
flock -n 9 || { log "another backup is already running, exiting"; exit 0; }

[[ -n "${DB_PASSWORD}" ]] || die "DB_PASSWORD (or MARIADB_ROOT_PASSWORD) is not set"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="${BACKUP_PREFIX}-${TIMESTAMP}"
WORK_DIR="${BACKUP_DIR}/.inprogress-${NAME}"
FINAL_DIR="${BACKUP_DIR}/${NAME}"
mkdir -p "${WORK_DIR}"

# Credentials go through a private defaults file, not argv (visible in ps).
DEFAULTS_FILE="$(mktemp)"
chmod 600 "${DEFAULTS_FILE}"
cat > "${DEFAULTS_FILE}" <<EOF
[client]
host=${DB_HOST}
port=${DB_PORT}
user=${DB_USER}
password=${DB_PASSWORD}
EOF

log "starting backup ${NAME}"

# ---- 1. database ------------------------------------------------------------
log "dumping database '${DB_NAME}' from ${DB_HOST}:${DB_PORT}"
mariadb-dump --defaults-extra-file="${DEFAULTS_FILE}" \
  --single-transaction --quick --routines --triggers --events --hex-blob \
  --default-character-set=utf8mb4 \
  --databases "${DB_NAME}" \
  | gzip -6 > "${WORK_DIR}/db.sql.gz"
gzip -t "${WORK_DIR}/db.sql.gz"

# ---- 2. resources -----------------------------------------------------------
if [[ -d "${RESOURCES_DIR}" ]]; then
  log "archiving ${RESOURCES_DIR}"
  tar -czf "${WORK_DIR}/resources.tar.gz" \
    --exclude='./cache' --exclude='*/node_modules' \
    -C "${RESOURCES_DIR}" .
else
  log "WARNING: ${RESOURCES_DIR} not found, skipping resources archive"
fi

# ---- 3. manifest + checksums ------------------------------------------------
{
  echo "name=${NAME}"
  echo "created_utc=${TIMESTAMP}"
  echo "db_host=${DB_HOST}"
  echo "db_name=${DB_NAME}"
  echo "resources_dir=${RESOURCES_DIR}"
  echo "host=$(hostname)"
} > "${WORK_DIR}/manifest.txt"

( cd "${WORK_DIR}" && sha256sum -- *.gz manifest.txt > SHA256SUMS )

mv "${WORK_DIR}" "${FINAL_DIR}"
WORK_DIR=""
log "local backup ready: ${FINAL_DIR} ($(du -sh "${FINAL_DIR}" | cut -f1))"

# ---- 4. upload --------------------------------------------------------------
if [[ -n "${BACKUP_REMOTE}" ]]; then
  log "uploading to ${BACKUP_REMOTE}/${NAME}"
  rclone copy --checksum --retries 3 --low-level-retries 10 \
    "${FINAL_DIR}" "${BACKUP_REMOTE}/${NAME}"
  # Verify what landed remotely matches local files.
  rclone check --one-way "${FINAL_DIR}" "${BACKUP_REMOTE}/${NAME}"

  log "applying remote retention (${BACKUP_KEEP_REMOTE_DAYS} days)"
  rclone delete --min-age "${BACKUP_KEEP_REMOTE_DAYS}d" "${BACKUP_REMOTE}"
  rclone rmdirs --leave-root "${BACKUP_REMOTE}" || true
else
  log "BACKUP_REMOTE empty: keeping backup local only (not recommended in production)"
fi

# ---- 5. local retention -----------------------------------------------------
mapfile -t backups < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d \
  -name "${BACKUP_PREFIX}-*" -printf '%f\n' | sort -r)
if (( ${#backups[@]} > BACKUP_KEEP_LOCAL )); then
  for old in "${backups[@]:BACKUP_KEEP_LOCAL}"; do
    log "pruning local backup ${old}"
    rm -rf "${BACKUP_DIR:?}/${old}"
  done
fi

ping_monitor ok
log "backup ${NAME} completed"
