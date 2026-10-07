#!/usr/bin/env bash
# reverse_check.sh — Reverse DNS & Visibility Monitor for sms.persiafava.com
# Checks whether external Iranian networks, cities & ISPs see our expected IP.

set -euo pipefail

DOMAIN="sms.persiafava.com"
EXPECTED_IP="185.49.84.46"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}   PFG SMS Reverse DNS & Network Visibility Checker             ${NC}"
echo -e "${BOLD}${CYAN}   Target: ${DOMAIN} -> Expected: ${EXPECTED_IP}                 ${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"

# Detect physical interface IP to bypass local VPN/TUN
PHYSICAL_IP=$(ip -4 route show table main default 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n 1 || true)
BIND_OPT=()
[[ -n "${PHYSICAL_IP}" ]] && BIND_OPT=(-b "${PHYSICAL_IP}")
echo -e "Physical Source IP: ${YELLOW}${PHYSICAL_IP:-Auto}${NC}\n"

echo -e "${BOLD}--- Part 1: Direct Probes across Iranian Resolvers & Provinces ---${NC}"
printf "%-20s %-16s %-16s %-10s\n" "Resolver / ISP" "DNS IP" "Resolved IP" "Status"
printf "%-20s %-16s %-16s %-10s\n" "--------------------" "----------------" "----------------" "----------"

declare -A LOCAL_PROBES=(
  ["TCI Tehran (Mokhaberat)"]="217.218.155.155"
  ["TCI Backup"]="217.218.127.127"
  ["TCI Fars (Shiraz)"]="2.189.242.10"
  ["MCI Data (Hamrah Aval)"]="194.225.62.80"
  ["Shecan Tehran"]="178.22.122.100"
  ["Shecan Shiraz/Mashhad"]="185.51.200.2"
  ["Begzar Tabriz/Tehran"]="185.55.226.26"
  ["Electro Primary"]="78.157.42.101"
  ["Electro Secondary"]="78.157.42.100"
  ["Bertina Authoritative"]="185.88.152.12"
  ["Cloudflare"]="1.1.1.1"
  ["Google"]="8.8.8.8"
  ["Quad9"]="9.9.9.9"
  ["OpenDNS"]="208.67.222.222"
)

for name in "${!LOCAL_PROBES[@]}"; do
  dns_ip="${LOCAL_PROBES[$name]}"
  res=$(dig "${BIND_OPT[@]}" @"$dns_ip" "$DOMAIN" A +short +time=2 +tries=2 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
  
  if [ -z "$res" ]; then
    printf "%-20s %-16s %-16s ${YELLOW}%-10s${NC}\n" "$name" "$dns_ip" "TIMEOUT" "TIMEOUT"
  elif [ "$res" = "$EXPECTED_IP" ]; then
    printf "%-20s %-16s %-16s ${GREEN}%-10s${NC}\n" "$name" "$dns_ip" "$res" "OK"
  else
    printf "%-20s %-16s %-16s ${RED}%-10s${NC}\n" "$name" "$dns_ip" "$res" "MISMATCH"
  fi
done

echo -e "\n${BOLD}--- Part 2: Remote Looking Glass (Nodes inside Iranian Cities) ---${NC}"
echo "Querying distributed nodes in Iran (Tehran, Isfahan, Shiraz, Qom)..."

NODES_PARAM="node=ir1.node.check-host.net&node=ir2.node.check-host.net&node=ir3.node.check-host.net&node=ir4.node.check-host.net&node=ir5.node.check-host.net&node=ir6.node.check-host.net&node=ir7.node.check-host.net&node=ir8.node.check-host.net"

REQ_JSON=$(curl -s "https://check-host.net/check-dns?host=${DOMAIN}&${NODES_PARAM}" -H "Accept: application/json" || true)
REQ_ID=$(echo "$REQ_JSON" | jq -r '.request_id // empty' 2>/dev/null || true)

if [ -z "$REQ_ID" ]; then
  echo -e "${YELLOW}Could not initiate remote check (check-host API unreachable).${NC}"
  exit 0
fi

# Wait for nodes to query
sleep 5
RES_JSON=$(curl -s "https://check-host.net/check-result/${REQ_ID}" -H "Accept: application/json" || true)

printf "%-10s %-12s %-12s %-16s %-10s\n" "Node" "City" "ASN" "Resolved IP" "Status"
printf "%-10s %-12s %-12s %-16s %-10s\n" "----------" "------------" "------------" "----------------" "----------"

declare -A NODE_INFO=(
  ["ir1.node.check-host.net"]="Tehran:AS47430"
  ["ir2.node.check-host.net"]="Isfahan:AS209279"
  ["ir3.node.check-host.net"]="Shiraz:AS213953"
  ["ir4.node.check-host.net"]="Shiraz:AS212077"
  ["ir5.node.check-host.net"]="Tehran:AS214431"
  ["ir6.node.check-host.net"]="Qom:AS206596"
  ["ir7.node.check-host.net"]="Tehran:AS213727"
  ["ir8.node.check-host.net"]="Tehran:AS214361"
)

for node in "${!NODE_INFO[@]}"; do
  info="${NODE_INFO[$node]}"
  city="${info%%:*}"
  asn="${info##*:}"
  
  resolved_ip=$(echo "$RES_JSON" | jq -r --arg n "$node" '.[$n][0].A[0] // empty' 2>/dev/null || true)
  node_short="${node%%.*}"

  if [ -z "$resolved_ip" ] || [ "$resolved_ip" = "null" ]; then
    printf "%-10s %-12s %-12s %-16s ${YELLOW}%-10s${NC}\n" "$node_short" "$city" "$asn" "NO_DATA" "PENDING"
  elif [ "$resolved_ip" = "$EXPECTED_IP" ]; then
    printf "%-10s %-12s %-12s %-16s ${GREEN}%-10s${NC}\n" "$node_short" "$city" "$asn" "$resolved_ip" "OK"
  else
    printf "%-10s %-12s %-12s %-16s ${RED}%-10s${NC}\n" "$node_short" "$city" "$asn" "$resolved_ip" "MISMATCH"
  fi
done

echo -e "\n${BOLD}${CYAN}================================================================${NC}"
echo -e "${GREEN}Reverse check completed successfully.${NC}"
