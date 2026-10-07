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
DNS_TIMEOUT=3

# Expanded Iranian ISPs, Provincial Resolvers & Public DNS
declare -A DNS_SERVERS=(
  ["TCI-Tehran"]="217.218.155.155"
  ["TCI-Backup"]="217.218.127.127"
  ["TCI-Fars"]="2.189.242.10"
  ["MCI-Data"]="194.225.62.80"
  ["Shecan-1"]="178.22.122.100"
  ["Shecan-2"]="185.51.200.2"
  ["Begzar"]="185.55.226.26"
  ["Electro-1"]="78.157.42.101"
  ["Electro-2"]="78.157.42.100"
  ["Bertina-NS"]="185.88.152.12"
  ["Cloudflare"]="1.1.1.1"
  ["Google"]="8.8.8.8"
  ["Quad9"]="9.9.9.9"
  ["OpenDNS"]="208.67.222.222"
)

log_dns_checks() {
  # Detect physical interface IP to bypass local VPN/TUN fake-IP (e.g. Clash/mihomo)
  local physical_ip bind_opt=()
  physical_ip=$(ip -4 route show table main default 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n 1 || true)
  [[ -n "${physical_ip}" ]] && bind_opt=(-b "${physical_ip}")

  for isp in "${!DNS_SERVERS[@]}"; do
    local dns_ip="${DNS_SERVERS[$isp]}"
    local resolved status message
    resolved=$(dig "${bind_opt[@]}" @"$dns_ip" "$DNS_DOMAIN" A +short \
      +time=$DNS_TIMEOUT +tries=2 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | head -n 1 || true)

    if [[ -z "$resolved" ]]; then
      sleep 1
      resolved=$(dig "${bind_opt[@]}" @"$dns_ip" "$DNS_DOMAIN" A +short \
        +time=$DNS_TIMEOUT +tries=2 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n 1 || true)
    fi

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

export_dns_json() {
  local json_file="/home/aria/projects/pfg-sms-monitor/dns_status.json"
  docker exec "${PG_CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" -t -A -c "
SELECT json_build_object(
  'domain', 'sms.persiafava.com',
  'expected_ip', '185.49.84.46',
  'updated_at', to_char(now() AT TIME ZONE 'Asia/Tehran', 'YYYY-MM-DD HH24:MI:SS'),
  'resolvers', json_agg(t)
) FROM (
  SELECT DISTINCT ON (isp_name)
    isp_name,
    dns_server,
    resolved_ip,
    status,
    message,
    to_char(checked_at AT TIME ZONE 'Asia/Tehran', 'YYYY-MM-DD HH24:MI:SS') as checked_at
  FROM dns_checks
  ORDER BY isp_name, checked_at DESC
) t;
" > "${json_file}" 2>/dev/null || true
}

log "--- db log start ---"
for name in "SMS Gateway" "SMS Panel" "Magfa Provider"; do
  check_and_record "${name}" "${SERVICES[${name}]}"
done
log_dns_checks
export_dns_json
log "--- db log end ---"
