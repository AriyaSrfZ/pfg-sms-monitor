#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${HOME}/.pfg-monitor.env"
LOG_FILE="${HOME}/pfg-notify.log"
TIMEOUT=10

declare -A SERVICES=(
  ["SMS Gateway"]="https://sms.persiafava.com/webservice/rest/"
  ["SMS Panel"]="https://sms.persiafava.com/login.php"
  ["Magfa Provider"]="https://sms.magfa.com/api/http/sms/v2"
)

NTFY_SERVER=""
NTFY_TOPIC=""
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

NTFY_URL=""
[[ -n "${NTFY_SERVER}" && -n "${NTFY_TOPIC}" ]] && NTFY_URL="${NTFY_SERVER}/${NTFY_TOPIC}"

timestamp() { TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S'; }
log()       { echo "[$(timestamp)] $*" >> "${LOG_FILE}"; }

notify() {
  local title="$1" msg="$2"
  [[ -z "${NTFY_URL}" ]] && return 0
  curl -s --max-time 5 \
    -H "Title: ${title}" \
    -H "Priority: high" \
    -d "${msg}" \
    "${NTFY_URL}" > /dev/null 2>&1 || true
}

check_service() {
  local name="$1" url="$2"
  local start end elapsed http_code status

  start=$(date +%s%3N)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time "${TIMEOUT}" -L "${url}" 2>/dev/null || echo "000")
  end=$(date +%s%3N)
  elapsed=$(( end - start ))

  if   [[ "${http_code}" == "000" ]];       then status="DOWN"
  elif [[ "${http_code}" =~ ^[23] ]];       then status="OK"
  else                                           status="WARN"
  fi

  log "${name}: ${status} (HTTP ${http_code}, ${elapsed}ms)"

  if [[ "${status}" != "OK" ]]; then
    notify "⚠️ SMS Monitor" "${name} is ${status} — HTTP ${http_code} after ${elapsed}ms"
  fi
}

# ── DNS / IP Resolution Check ──────────────────────────────────────
DNS_DOMAIN="sms.persiafava.com"
DNS_EXPECTED_IP="185.49.84.46"
DNS_TIMEOUT=2

# Expanded Iranian ISPs & Public Resolvers
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

check_dns_resolution() {
  local failed_isps=()

  # Detect physical interface IP to bypass local VPN/TUN fake-IP (e.g. Clash/mihomo)
  local physical_ip bind_opt=()
  physical_ip=$(ip -4 route show table main default 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n 1 || true)
  [[ -n "${physical_ip}" ]] && bind_opt=(-b "${physical_ip}")

  for isp in "${!DNS_SERVERS[@]}"; do
    local dns_ip="${DNS_SERVERS[$isp]}"
    local resolved
    resolved=$(dig "${bind_opt[@]}" @"$dns_ip" "$DNS_DOMAIN" A +short \
      +time=$DNS_TIMEOUT +tries=2 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | head -n 1 || true)

    if [ -z "$resolved" ]; then
      failed_isps+=("$isp ($dns_ip): TIMEOUT (no response)")
    elif [ "$resolved" != "$DNS_EXPECTED_IP" ]; then
      failed_isps+=("$isp ($dns_ip): MISMATCH (got $resolved, expected $DNS_EXPECTED_IP)")
    fi
  done

  if [ ${#failed_isps[@]} -gt 0 ]; then
    local alert_title="🚨 DNS Alert: ${#failed_isps[@]} resolver failure(s)"
    local msg="⚠️ DNS Alert for ${DNS_DOMAIN}
Expected IP: ${DNS_EXPECTED_IP}
Failed Resolvers (${#failed_isps[@]}):"
    for err in "${failed_isps[@]}"; do
      msg+=$'\n'"• ${err}"
    done

    echo "[$(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S')] DNS ALERT for $DNS_DOMAIN | Failed: ${failed_isps[*]}" >> /home/aria/projects/pfg-sms-monitor/pfg-notify.log
    [[ "${LOG_FILE}" != "/home/aria/projects/pfg-sms-monitor/pfg-notify.log" ]] && echo "[$(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S')] DNS ALERT for $DNS_DOMAIN | Failed: ${failed_isps[*]}" >> "${LOG_FILE}"

    curl -s -o /dev/null \
      -H "Title: ${alert_title}" \
      -H "Priority: high" \
      -H "Tags: warning,dns" \
      -d "${msg}" \
      https://ntfy.sh/HealthAlerts
  else
    echo "[$(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S')] DNS OK — all ISPs resolved $DNS_DOMAIN to $DNS_EXPECTED_IP" >> /home/aria/projects/pfg-sms-monitor/pfg-notify.log
    [[ "${LOG_FILE}" != "/home/aria/projects/pfg-sms-monitor/pfg-notify.log" ]] && echo "[$(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S')] DNS OK — all ISPs resolved $DNS_DOMAIN to $DNS_EXPECTED_IP" >> "${LOG_FILE}"
  fi
}

log "--- notify check start ---"
for name in "SMS Gateway" "SMS Panel" "Magfa Provider"; do
  check_service "${name}" "${SERVICES[${name}]}"
done
check_dns_resolution
log "--- notify check end ---"
