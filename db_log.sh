#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${HOME}/pfg-db.log"
TIMEOUT=10
PG_CONTAINER="pfg-postgres"
PG_USER="pfg"
PG_DB="pfg_monitor"

declare -A SERVICES=(
  ["SMS Gateway"]="https://sms.persiafava.com/webservice/rest/"
  ["SMS Panel"]="https://sms.persiafava.com/login.php"
  ["Magfa Provider"]="https://sms.magfa.com/api/http/sms/v2"
)

timestamp() { TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S'; }
log()       { echo "[$(timestamp)] $*" >> "${LOG_FILE}"; }

insert_db() {
  local name="$1" status="$2" http_code="$3" elapsed="$4"
  local name_escaped="${name//\'/\'\'}"
  docker exec "${PG_CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" -c \
    "SET timezone = 'Asia/Tehran'; INSERT INTO sms_checks (service, status, http_code, response_time_ms) VALUES ('${name_escaped}', '${status}', ${http_code}, ${elapsed});" \
    > /dev/null 2>&1 \
    || log "WARN: DB insert failed for ${name} (is pfg-postgres running?)"
}

check_and_record() {
  local name="$1" url="$2"
  local start end elapsed http_code status

  start=$(date +%s%3N)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time "${TIMEOUT}" -L "${url}" 2>/dev/null || echo "000")
  end=$(date +%s%3N)
  elapsed=$(( end - start ))

  if   [[ "${http_code}" == "000" ]];   then status="DOWN"
  elif [[ "${http_code}" =~ ^[23] ]];   then status="OK"
  else                                       status="WARN"
  fi

  log "${name}: ${status} (HTTP ${http_code}, ${elapsed}ms)"
  insert_db "${name}" "${status}" "${http_code}" "${elapsed}"
}

# ── DNS / IP Resolution DB Logger ──────────────────────────────────
DNS_DOMAIN="sms.persiafava.com"
DNS_EXPECTED_IP="185.49.84.46"
DNS_TIMEOUT=2
declare -A DNS_SERVERS=(
  ["MCI"]="5.200.200.200"
  ["Irancell"]="109.96.8.8"
  ["TCI"]="2.188.242.80"
  ["TCI-Backup"]="217.218.155.155"
  ["Shatel"]="85.15.1.14"
  ["Asiatech"]="194.225.70.10"
  ["Shecan"]="178.22.122.100"
  ["Cloudflare"]="1.1.1.1"
  ["Google"]="8.8.8.8"
)

log_dns_checks() {
  for isp in "${!DNS_SERVERS[@]}"; do
    local dns_ip="${DNS_SERVERS[$isp]}"
    local resolved status message
    resolved=$(dig @"$dns_ip" "$DNS_DOMAIN" A +short \
      +time=$DNS_TIMEOUT +tries=1 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | head -n 1 || true)

    if [ -z "$resolved" ]; then
      status="timeout"
      message="No response from $dns_ip"
      resolved="NULL"
    elif [ "$resolved" = "$DNS_EXPECTED_IP" ]; then
      status="ok"
      message="Resolved correctly"
    else
      status="mismatch"
      message="Expected $DNS_EXPECTED_IP but got $resolved"
    fi

    # Build resolved_ip value (NULL or quoted string)
    local resolved_sql
    if [ "$resolved" = "NULL" ]; then
      resolved_sql="NULL"
    else
      resolved_sql="'$resolved'"
    fi

    docker exec pfg-postgres psql -U pfg -d pfg_monitor -c \
"SET timezone = 'Asia/Tehran';
INSERT INTO dns_checks
(domain, expected_ip, isp_name, dns_server, resolved_ip, status, message)
VALUES
('$DNS_DOMAIN', '$DNS_EXPECTED_IP', '$isp', '$dns_ip',
$resolved_sql, '$status', '$message');" \
      >> /home/aria/projects/pfg-sms-monitor/pfg-db.log 2>&1

    echo "[$(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S')] DNS LOG — $isp ($dns_ip): $status | $message" \
      >> /home/aria/projects/pfg-sms-monitor/pfg-db.log
    [[ "${LOG_FILE}" != "/home/aria/projects/pfg-sms-monitor/pfg-db.log" ]] && echo "[$(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S')] DNS LOG — $isp ($dns_ip): $status | $message" >> "${LOG_FILE}"
  done
}

log "--- db log start ---"
for name in "SMS Gateway" "SMS Panel" "Magfa Provider"; do
  check_and_record "${name}" "${SERVICES[${name}]}"
done
log_dns_checks
log "--- db log end ---"
