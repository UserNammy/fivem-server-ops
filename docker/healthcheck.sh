#!/usr/bin/env bash
# Container healthcheck: the server is healthy when its HTTP endpoint answers
# /info.json with valid JSON. A crashed or hung FXServer stops answering.
set -euo pipefail

# In txAdmin mode the game server may legitimately be stopped (first-run
# setup, scheduled restart), so only the panel itself is checked.
if [[ "${TXADMIN_ENABLED:-false}" == "true" ]]; then
  curl --fail --silent --output /dev/null --max-time 4 \
    "http://127.0.0.1:${TXHOST_TXA_PORT:-40120}/" || {
    echo "unhealthy: txAdmin panel not responding" >&2
    exit 1
  }
  exit 0
fi

PORT="${FIVEM_PORT:-30120}"
URL="http://127.0.0.1:${PORT}/info.json"

body="$(curl --fail --silent --show-error --max-time 4 "${URL}")" || {
  echo "unhealthy: ${URL} did not respond" >&2
  exit 1
}

# Cheap sanity check without pulling jq into the image.
if [[ "${body}" != \{* ]]; then
  echo "unhealthy: ${URL} returned non-JSON payload" >&2
  exit 1
fi

exit 0
