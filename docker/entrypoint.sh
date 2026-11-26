#!/usr/bin/env bash
# FXServer container entrypoint.
#
# Two modes:
#   TXADMIN_ENABLED=false (default) -> render server.cfg from the template and
#                                      start FXServer directly (+exec).
#   TXADMIN_ENABLED=true            -> start FXServer without +exec so txAdmin
#                                      takes over process management. txAdmin
#                                      then owns the server.cfg it launches.
set -Eeuo pipefail

log() { printf '[entrypoint] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

FXSERVER_DIR="${FXSERVER_DIR:-/opt/fxserver}"
SERVER_DATA_DIR="${SERVER_DATA_DIR:-/srv/fivem/server-data}"
TEMPLATE="${SERVER_CFG_TEMPLATE:-/opt/fivem/server.cfg.template}"
RENDERED_CFG="${SERVER_CFG_PATH:-/srv/fivem/config/server.cfg}"

# Only these variables are substituted. Anything else that looks like $FOO in
# the template (e.g. inside a convar value) is left untouched.
TEMPLATE_VARS=(
  FIVEM_PORT
  FIVEM_HOSTNAME
  FIVEM_PROJECT_NAME
  FIVEM_PROJECT_DESC
  FIVEM_TAGS
  FIVEM_LOCALE
  FIVEM_MAX_CLIENTS
  FIVEM_GAME_BUILD
  FIVEM_LICENSE_KEY
  STEAM_WEBAPIKEY
  MYSQL_CONNECTION_STRING
)

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "environment variable ${name} is required"
}

render_config() {
  require_env FIVEM_LICENSE_KEY
  require_env MYSQL_CONNECTION_STRING

  if [[ "${FIVEM_LICENSE_KEY}" == *changeme* ]]; then
    die "FIVEM_LICENSE_KEY still contains the placeholder value"
  fi

  # Sensible defaults for optional values
  export FIVEM_PORT="${FIVEM_PORT:-30120}"
  export FIVEM_HOSTNAME="${FIVEM_HOSTNAME:-fivem-server-ops dev server}"
  export FIVEM_PROJECT_NAME="${FIVEM_PROJECT_NAME:-fivem-server-ops}"
  export FIVEM_PROJECT_DESC="${FIVEM_PROJECT_DESC:-Containerized FXServer}"
  export FIVEM_TAGS="${FIVEM_TAGS:-default}"
  export FIVEM_LOCALE="${FIVEM_LOCALE:-en-US}"
  export FIVEM_MAX_CLIENTS="${FIVEM_MAX_CLIENTS:-48}"
  export FIVEM_GAME_BUILD="${FIVEM_GAME_BUILD:-3095}"
  export STEAM_WEBAPIKEY="${STEAM_WEBAPIKEY:-}"

  [[ -r "${TEMPLATE}" ]] || die "template not readable: ${TEMPLATE}"
  mkdir -p "$(dirname "${RENDERED_CFG}")"

  local shell_format=""
  local v
  for v in "${TEMPLATE_VARS[@]}"; do
    shell_format+="\${${v}} "
  done

  # Write atomically and keep the file private: it contains the license key.
  umask 077
  envsubst "${shell_format}" < "${TEMPLATE}" > "${RENDERED_CFG}.tmp"
  mv "${RENDERED_CFG}.tmp" "${RENDERED_CFG}"
  log "rendered ${RENDERED_CFG} from ${TEMPLATE}"
}

check_resources() {
  if [[ -z "$(ls -A "${SERVER_DATA_DIR}/resources" 2>/dev/null)" ]]; then
    log "WARNING: ${SERVER_DATA_DIR}/resources is empty. Mount your resources" \
        "(e.g. citizenfx/cfx-server-data) or the server will start with nothing to ensure."
  fi
}

main() {
  [[ -x "${FXSERVER_DIR}/run.sh" ]] || die "FXServer not found in ${FXSERVER_DIR}"
  cd "${SERVER_DATA_DIR}"
  check_resources

  # Allow `docker run ... <cmd>` for debugging (e.g. bash).
  if [[ $# -gt 0 && "$1" != +* ]]; then
    exec "$@"
  fi

  if [[ "${TXADMIN_ENABLED,,}" == "true" ]]; then
    log "starting FXServer under txAdmin (panel port ${TXHOST_TXA_PORT:-40120}, data ${TXHOST_DATA_PATH:-unset})"
    exec "${FXSERVER_DIR}/run.sh" "$@"
  fi

  render_config
  log "starting FXServer in standalone mode on port ${FIVEM_PORT}"
  exec "${FXSERVER_DIR}/run.sh" +exec "${RENDERED_CFG}" "$@"
}

main "$@"
