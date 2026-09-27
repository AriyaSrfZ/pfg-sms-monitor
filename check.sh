#!/usr/bin/env bash
# PFG SMS Health Monitor — server-side cron checker
# Place secrets in ~/.pfg-monitor.env (chmod 600)
# Requires: curl, bc

set -euo pipefail

ENV_FILE="${HOME}/.pfg-monitor.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# Required vars from env file:
# NTFY_TOPIC   e.g. HealthAlerts
# NTFY_SERVER  e.g. https://ntfy.sh  (no trailing slash)

NTFY_URL="${NTFY_SERVER}/${NTFY_TOPIC}"
LOG_FILE="${HOME}/pfg-monitor.log"
TIMEOUT=10  # seconds per check

declare -A SERVICES
SERVICES["SMS Gateway"]="https://sms.persiafava.com/webservice/rest/"
SERVICES["SMS Panel"]="https://sms.persiafava.com/login.php"
SERVICES["Magfa Provider API"]="https://sms.magfa.com/api/http/sms/v2"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"
}

notify() {
  local title="$1" message="$2" priority="$3" tags="$4"
  curl -s -o /dev/null \
    -H "Title: ${title}" \
    -H "Priority: ${priority}" \
    -H "Tags: ${tags}" \
    -d "${message}" \
    "${NTFY_URL}" || log "WARN: ntfy notification failed for '${title}'"
}

check_service() {
  local name="$1" url="$2"
  local start http_code elapsed

  start=$(date +%s%3N)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$TIMEOUT" \
    --connect-timeout 5 \
    -L "$url" 2>/dev/null || echo "000")
  elapsed=$(( $(date +%s%3N) - start ))

  if [[ "$http_code" =~ ^(2|3)[0-9]{2}$ ]]; then
    log "OK | ${name} | HTTP ${http_code} | ${elapsed}ms"
    # Uncomment below to notify on every healthy check (verbose):
    # notify "✅ ${name}" "UP — HTTP ${http_code} | ${elapsed}ms" "min" "white_check_mark"
  elif [[ "$http_code" == "000" ]]; then
    log "DOWN | ${name} | timeout/unreachable | ${elapsed}ms"
    notify "${name} is DOWN" \
      "Unreachable (timeout or connection refused) after ${elapsed}ms" \
      "high" "rotating_light"
  else
    log "WARN | ${name} | HTTP ${http_code} | ${elapsed}ms"
    notify "${name} — HTTP ${http_code}" \
      "Unexpected status ${http_code} | ${elapsed}ms" \
      "default" "warning"
  fi
}

log "--- Starting health check run ---"
for name in "${!SERVICES[@]}"; do
  check_service "$name" "${SERVICES[$name]}"
done
log "--- Done ---"
