#!/bin/bash
# =============================================================================
# Purple Team Lab - 전체 상태 점검 스크립트
# Agent VM에서 실행
# =============================================================================

command -v sshpass &>/dev/null || sudo apt-get install -y sshpass

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

check_service() {
    local host=$1 user=$2 pass=$3 service=$4
    STATUS=$(sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${user}@${host}" \
        "echo '$pass' | sudo -S systemctl is-active $service 2>/dev/null" 2>/dev/null | tail -1)
    if [ "$STATUS" = "active" ]; then
        echo -e "  ${GREEN}[active]${NC}  $service"
    else
        echo -e "  ${RED}[${STATUS:-error}]${NC} $service"
    fi
}

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Purple Team Lab - Status Check             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Agent ─────────────────────────────────────
echo -e "${YELLOW}[Agent] 192.168.193.129 / 10.10.10.100${NC}"
ping -c 1 -W 1 192.168.193.129 &>/dev/null && echo -e "  ${GREEN}[online]${NC}  ping" || echo -e "  ${RED}[offline]${NC} ping"
ip addr show ens37 2>/dev/null | grep -q "10.10.10.100" && echo -e "  ${GREEN}[OK]${NC}     내부 IP (10.10.10.100)" || echo -e "  ${RED}[MISS]${NC}   내부 IP 없음"
echo ""

# ── Security ─────────────────────────────────
echo -e "${YELLOW}[Security] 192.168.193.131 / 10.10.10.1${NC}"
ping -c 1 -W 1 192.168.193.131 &>/dev/null && echo -e "  ${GREEN}[online]${NC}  ping" || echo -e "  ${RED}[offline]${NC} ping"
check_service 192.168.193.131 security security nftables
check_service 192.168.193.131 security security suricata
check_service 192.168.193.131 security security wazuh-agent

RULES=$(sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 \
    "echo security | sudo -S bash -c 'grep -c ^ /var/lib/suricata/rules/suricata.rules 2>/dev/null || echo 0'" 2>/dev/null | tail -1)
echo "  Suricata 규칙: ${RULES}개"

EVE_LINES=$(sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 \
    "echo security | sudo -S wc -l /var/log/suricata/eve.json 2>/dev/null" 2>/dev/null | awk '{print $1}')
echo "  Eve.json 이벤트: ${EVE_LINES:-0}개"
echo ""

# ── Web ──────────────────────────────────────
echo -e "${YELLOW}[Web] 192.168.193.130 / 10.10.10.80${NC}"
ping -c 1 -W 1 192.168.193.130 &>/dev/null && echo -e "  ${GREEN}[online]${NC}  ping" || echo -e "  ${RED}[offline]${NC} ping"
check_service 192.168.193.130 web web apache2
check_service 192.168.193.130 web web wazuh-agent
check_service 192.168.193.130 web web docker

JUICE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://10.10.10.80/ 2>/dev/null)
[ "$JUICE_HTTP" = "200" ] && echo -e "  ${GREEN}[HTTP $JUICE_HTTP]${NC} Juice Shop" || echo -e "  ${RED}[HTTP $JUICE_HTTP]${NC} Juice Shop"

MODSEC_LINES=$(sshpass -p web ssh -o StrictHostKeyChecking=no web@192.168.193.130 \
    "echo web | sudo -S wc -l /var/log/apache2/modsec_audit.log 2>/dev/null" 2>/dev/null | awk '{print $1}')
echo "  ModSecurity 이벤트: ${MODSEC_LINES:-0}개"
echo ""

# ── SIEM ─────────────────────────────────────
echo -e "${YELLOW}[SIEM] 192.168.193.132 / 10.10.10.50${NC}"
ping -c 1 -W 1 192.168.193.132 &>/dev/null && echo -e "  ${GREEN}[online]${NC}  ping" || echo -e "  ${RED}[offline]${NC} ping"
check_service 192.168.193.132 siem siem wazuh-manager
check_service 192.168.193.132 siem siem wazuh-indexer
check_service 192.168.193.132 siem siem wazuh-dashboard

WAZUH_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -k https://192.168.193.132/ 2>/dev/null)
[ "$WAZUH_HTTP" = "302" ] || [ "$WAZUH_HTTP" = "200" ] && \
    echo -e "  ${GREEN}[HTTP $WAZUH_HTTP]${NC} Wazuh Dashboard → https://192.168.193.132/" || \
    echo -e "  ${RED}[HTTP $WAZUH_HTTP]${NC} Wazuh Dashboard"

AGENTS=$(sshpass -p siem ssh -o StrictHostKeyChecking=no siem@192.168.193.132 \
    "echo siem | sudo -S /var/ossec/bin/agent_control -l 2>/dev/null" 2>/dev/null | grep "Active" | grep -v "Local")
AGENT_COUNT=$(echo "$AGENTS" | grep -c "Active" 2>/dev/null || echo 0)
echo "  연결된 에이전트: ${AGENT_COUNT}개"
echo "$AGENTS" | while read line; do [ -n "$line" ] && echo "    → $line"; done
echo ""

echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo "Wazuh 대시보드: https://192.168.193.132/"
echo "Juice Shop:     http://192.168.193.130/"
