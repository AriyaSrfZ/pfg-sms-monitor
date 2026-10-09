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
TCI_LOG_ONLY="false"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

NTFY_URL=""
[[ -n "${NTFY_SERVER}" && -n "${NTFY_TOPIC}" ]] && NTFY_URL="${NTFY_SERVER}/${NTFY_TOPIC}"

timestamp() { TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S'; }
log()       { echo "[$(timestamp)] $*" >> "${LOG_FILE}"; }

notify() {
  local title="$1" msg="$2" priority="${3:-high}" tags="${4:-warning}"
  local url="${NTFY_URL:-https://ntfy.sh/HealthAlerts}"
  [[ -z "${url}" ]] && return 0
  curl -s --max-time 5 \
    -H "Title: ${title}" \
    -H "Priority: ${priority}" \
    -H "Tags: ${tags}" \
    -d "${msg}" \
    "${url}" > /dev/null 2>&1 || true
}

check_service() {
  local name="$1" url="$2"
  local start end elapsed http_code status
  local svc_key="${name// /_}"
  local alert_file="${DNS_STATE_DIR}/svc_${svc_key}.alerted"

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
    local now_ts last_alert=0
    now_ts=$(date +%s)
    [[ -f "$alert_file" ]] && last_alert=$(cat "$alert_file" 2>/dev/null || echo 0)
    if (( last_alert == 0 )) || (( now_ts - last_alert >= 3600 )); then
      notify "⚠️ SMS Monitor" "${name} is ${status} — HTTP ${http_code} after ${elapsed}ms" "high" "warning"
      echo "$now_ts" > "$alert_file"
    fi
  else
    if [[ -f "$alert_file" ]]; then
      notify "✅ SMS Monitor Recovered" "${name} is OK (HTTP ${http_code}, ${elapsed}ms)" "low" "white_check_mark"
      rm -f "$alert_file"
    fi
  fi
}

# ── DNS / IP Resolution Check ──────────────────────────────────────
DNS_DOMAIN="sms.persiafava.com"
DNS_EXPECTED_IP="185.49.84.46"
DNS_TIMEOUT=3

# Anti-flap state tracking: 20 minutes debounce (4 consecutive 5-min checks)
DNS_FAIL_THRESHOLD=4
DNS_STATE_DIR="${HOME}/.pfg-dns-state"
mkdir -p "${DNS_STATE_DIR}"

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
  local recovered_isps=()
  local has_non_tci_failure=false
  local has_mismatch=false

  # Detect physical interface IP to bypass local VPN/TUN fake-IP (e.g. Clash/mihomo)
  local physical_ip bind_opt=()
  physical_ip=$(ip -4 route show table main default 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n 1 || true)
  [[ -n "${physical_ip}" ]] && bind_opt=(-b "${physical_ip}")

  for isp in "${!DNS_SERVERS[@]}"; do
    local dns_ip="${DNS_SERVERS[$isp]}"
    local is_tci=false
    [[ "$isp" == TCI-* ]] && is_tci=true

    # Probe with quick retry to prevent single transient UDP packet loss false alarms
    local resolved
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

    local fail_file="${DNS_STATE_DIR}/${isp}.fails"
    local alert_file="${DNS_STATE_DIR}/${isp}.alerted"

    if [[ -z "$resolved" ]]; then
      # Resolver timed out
      local fails=0
      [[ -f "$fail_file" ]] && fails=$(cat "$fail_file" 2>/dev/null || echo 0)
      fails=$(( fails + 1 ))
      echo "$fails" > "$fail_file"

      # Check if threshold reached (20 minutes = 4 consecutive cycles)
      if (( fails >= DNS_FAIL_THRESHOLD )); then
        if [[ "$is_tci" == true && "${TCI_LOG_ONLY,,}" == "true" ]]; then
          log "DNS TCI-LOG-ONLY — $isp ($dns_ip): timeout for ${fails} checks (>=20m), push alert suppressed"
        else
          local now_ts last_alert=0
          now_ts=$(date +%s)
          [[ -f "$alert_file" ]] && last_alert=$(cat "$alert_file" 2>/dev/null || echo 0)

          # Notify ONCE on initial failure. Only re-notify if down for >= 1 hour (3600s)
          if (( last_alert == 0 )) || (( now_ts - last_alert >= 3600 )); then
            failed_isps+=("$isp ($dns_ip): TIMEOUT (${fails} cycles / $(( fails * 5 ))m)")
            [[ "$is_tci" == false ]] && has_non_tci_failure=true
            echo "$now_ts" > "$alert_file"
          else
            log "DNS TIMEOUT PERSISTS — $isp ($dns_ip): ${fails} cycles ($(( fails * 5 ))m), suppressed (alerted $(( (now_ts - last_alert) / 60 ))m ago)"
          fi
        fi
      else
        log "DNS DEBOUNCE — $isp ($dns_ip): timeout count ${fails}/${DNS_FAIL_THRESHOLD} (debouncing for 20m threshold)"
      fi

    elif [[ "$resolved" != "$DNS_EXPECTED_IP" ]]; then
      # Critical IP MISMATCH — immediate alert, zero debounce delay
      has_mismatch=true
      [[ "$is_tci" == false ]] && has_non_tci_failure=true
      failed_isps+=("$isp ($dns_ip): CRITICAL MISMATCH (got $resolved, expected $DNS_EXPECTED_IP)")
      log "DNS MISMATCH — $isp ($dns_ip): got $resolved, expected $DNS_EXPECTED_IP"

    else
      # Resolution succeeded
      if [[ -f "$alert_file" ]]; then
        recovered_isps+=("$isp ($dns_ip)")
      fi
      rm -f "$fail_file" "$alert_file"
    fi
  done

  # Send recovery alerts if previously failing resolvers came back
  if [ ${#recovered_isps[@]} -gt 0 ]; then
    local rec_msg="✅ DNS Recovery for ${DNS_DOMAIN}:"
    for r in "${recovered_isps[@]}"; do
      rec_msg+=$'\n'"• ${r} resolved correctly"
    done
    log "DNS RECOVERY — ${recovered_isps[*]}"
    notify "✅ DNS Resolved" "${rec_msg}" "low" "white_check_mark,dns"
  fi

  # Send failure alerts if any threshold has been breached
  if [ ${#failed_isps[@]} -gt 0 ]; then
    local alert_title alert_priority alert_tags
    if [[ "$has_mismatch" == true ]]; then
      alert_priority="urgent"
      alert_title="🚨 CRITICAL: DNS IP Mismatch on ${DNS_DOMAIN}"
      alert_tags="rotating_light,dns"
    elif [[ "$has_non_tci_failure" == true ]]; then
      alert_priority="high"
      alert_title="⚠️ DNS Alert: Resolver failure(s) (>=20m)"
      alert_tags="warning,dns"
    else
      # All failures are TCI timeouts — low priority notification
      alert_priority="low"
      alert_title="ℹ️ TCI DNS Latency (20m+ Timeout)"
      alert_tags="information,dns"
    fi

    local msg="DNS Alert for ${DNS_DOMAIN}
Expected IP: ${DNS_EXPECTED_IP}
Affected Resolvers (${#failed_isps[@]}):"
    for err in "${failed_isps[@]}"; do
      msg+=$'\n'"• ${err}"
    done

    log "DNS ALERT for ${DNS_DOMAIN} [Priority: ${alert_priority}] | ${failed_isps[*]}"
    notify "${alert_title}" "${msg}" "${alert_priority}" "${alert_tags}"
  else
    log "DNS OK — all active ISPs resolved ${DNS_DOMAIN} to ${DNS_EXPECTED_IP}"
  fi
}

log "--- notify check start ---"
for name in "SMS Gateway" "SMS Panel" "Magfa Provider"; do
  check_service "${name}" "${SERVICES[${name}]}"
done
check_dns_resolution
log "--- notify check end ---"
