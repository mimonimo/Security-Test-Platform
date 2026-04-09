#!/bin/bash
# =============================================================================
# Purple Team Lab - Full Setup Script
# Ubuntu 22.04 기반 4-VM 보안 실습 환경 자동 구성
# 교육 목적 전용
#
# 사용법:
#   ./setup-all.sh                    # 기본값으로 실행
#   ./setup-all.sh --help             # 도움말
#
# 실행 전 필수 확인:
#   1. 이 스크립트는 Agent VM에서 실행합니다.
#   2. 각 VM에 두 번째 NIC(ens37)이 연결되어 있어야 합니다.
#   3. 모든 VM이 인터넷에 연결되어 있어야 합니다.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# [설정] 환경에 맞게 이 섹션만 수정하세요
# ─────────────────────────────────────────────────────────────────────────────

# 외부 IP (SSH 접속용)
AGENT_EXT_IP="192.168.193.129"
SECURITY_EXT_IP="192.168.193.131"
WEB_EXT_IP="192.168.193.130"
SIEM_EXT_IP="192.168.193.132"

# SSH 계정 (사용자명 = 비밀번호 형태)
AGENT_USER="agent"
SECURITY_USER="security"
WEB_USER="web"
SIEM_USER="siem"

# 내부망 IP (ens37에 설정될 IP)
AGENT_INT_IP="10.10.10.100"
SECURITY_INT_IP="10.10.10.1"      # 내부망 게이트웨이
WEB_INT_IP="10.10.10.80"
SIEM_INT_IP="10.10.10.50"
INTERNAL_NET="10.10.10.0/24"

# 네트워크 인터페이스 이름
EXT_IFACE="ens33"   # 외부망 인터페이스
INT_IFACE="ens37"   # 내부망 인터페이스 (두 번째 NIC)

# ─────────────────────────────────────────────────────────────────────────────
# 색상 출력 함수
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()     { echo -e "${RED}[ERR ]${NC}  $1" >&2; }
step()    { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${CYAN}  STEP $1${NC}"; \
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=no"

# 원격 서버에서 sudo 명령 실행
remote() {
    local host=$1 user=$2 pass=$3
    shift 3
    sshpass -p "$pass" ssh $SSH_OPTS "${user}@${host}" \
        "echo '$pass' | sudo -S bash -s" <<< "$@" 2>&1
}

# 사전 조건 확인
preflight() {
    info "사전 조건 확인 중..."
    command -v sshpass &>/dev/null || { info "sshpass 설치 중..."; sudo apt-get install -y sshpass; }
    command -v curl    &>/dev/null || { info "curl 설치 중...";    sudo apt-get install -y curl; }

    for vm in "${SECURITY_USER}@${SECURITY_EXT_IP}" "${WEB_USER}@${WEB_EXT_IP}" "${SIEM_USER}@${SIEM_EXT_IP}"; do
        user="${vm%%@*}"; host="${vm##*@}"
        if sshpass -p "$user" ssh $SSH_OPTS "${user}@${host}" "echo ok" &>/dev/null; then
            ok "SSH 연결: $host"
        else
            err "SSH 연결 실패: $host - 접속 정보를 확인하세요"
            exit 1
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 : 내부망 IP 설정 (모든 VM)
# ─────────────────────────────────────────────────────────────────────────────
setup_network() {
    step "1/5 내부망 네트워크 설정 (${INTERNAL_NET})"

    # Agent (로컬 실행)
    sudo bash -c "
cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ${INT_IFACE}:
      addresses:
        - ${AGENT_INT_IP}/24
      routes:
        - to: ${INTERNAL_NET}
          via: ${SECURITY_INT_IP}
          metric: 100
EOF
chmod 600 /etc/netplan/99-internal.yaml
netplan apply"
    ok "Agent: ${AGENT_INT_IP}"

    # Security (게이트웨이 + IP 포워딩)
    remote "$SECURITY_EXT_IP" "$SECURITY_USER" "$SECURITY_USER" "
chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ${INT_IFACE}:
      addresses:
        - ${SECURITY_INT_IP}/24
EOF
chmod 600 /etc/netplan/99-internal.yaml

# IP 포워딩 활성화 (중복 추가 방지)
grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
grep -q 'send_redirects=0' /etc/sysctl.conf       || echo 'net.ipv4.conf.all.send_redirects=0' >> /etc/sysctl.conf
sysctl -p
netplan apply"
    ok "Security: ${SECURITY_INT_IP} (게이트웨이, IP 포워딩 활성화)"

    # Web
    remote "$WEB_EXT_IP" "$WEB_USER" "$WEB_USER" "
chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ${INT_IFACE}:
      addresses:
        - ${WEB_INT_IP}/24
      routes:
        - to: ${INTERNAL_NET}
          via: ${SECURITY_INT_IP}
          metric: 100
EOF
chmod 600 /etc/netplan/99-internal.yaml
netplan apply"
    ok "Web: ${WEB_INT_IP}"

    # SIEM
    remote "$SIEM_EXT_IP" "$SIEM_USER" "$SIEM_USER" "
chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ${INT_IFACE}:
      addresses:
        - ${SIEM_INT_IP}/24
      routes:
        - to: ${INTERNAL_NET}
          via: ${SECURITY_INT_IP}
          metric: 100
EOF
chmod 600 /etc/netplan/99-internal.yaml
netplan apply"
    ok "SIEM: ${SIEM_INT_IP}"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 : Security - nftables + Suricata IPS
# ─────────────────────────────────────────────────────────────────────────────
setup_security() {
    step "2/5 Security 서버 - nftables + Suricata IPS"

    remote "$SECURITY_EXT_IP" "$SECURITY_USER" "$SECURITY_USER" "
set -e
# ── Suricata 설치 ──────────────────────────────
add-apt-repository -y ppa:oisf/suricata-stable
apt-get update -q
apt-get install -y suricata nftables curl rsyslog

# ── Suricata 설정 ──────────────────────────────
cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak

# HOME_NET 변경
sed -i 's|HOME_NET: \"\[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12\]\"|HOME_NET: \"[${INTERNAL_NET}]\"|' /etc/suricata/suricata.yaml

# af-packet 인터페이스를 ${INT_IFACE}로 설정
# 기존 af-packet 블록의 첫 번째 interface 항목만 교체
python3 -c \"
import re, sys
content = open('/etc/suricata/suricata.yaml').read()
# af-packet 섹션의 첫 interface 값 교체
content = re.sub(
    r'(af-packet:\s*\n\s*-\s*interface:)\s*\S+',
    r'\1 ${INT_IFACE}',
    content, count=1
)
open('/etc/suricata/suricata.yaml', 'w').write(content)
print('af-packet interface set to ${INT_IFACE}')
\"

# ── Suricata 규칙 업데이트 ─────────────────────
suricata-update

# ── nftables 설정 ─────────────────────────────
cat > /etc/nftables.conf << 'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        iif lo accept
        ct state established,related accept
        tcp dport 22 accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        iif \"${INT_IFACE}\" ip saddr ${INTERNAL_NET} accept
        log prefix \"NFT-INPUT: \" level warn
        accept
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
        log prefix \"NFT-FORWARD: \" level info
        accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oif \"${EXT_IFACE}\" ip saddr ${INTERNAL_NET} masquerade
    }
}
NFTEOF

# nftables 인터페이스 변수 실제 값으로 치환
sed -i 's|\${INT_IFACE}|${INT_IFACE}|g; s|\${EXT_IFACE}|${EXT_IFACE}|g; s|\${INTERNAL_NET}|${INTERNAL_NET}|g' /etc/nftables.conf

nft -f /etc/nftables.conf

# ── rsyslog - nftables 로그 분리 ──────────────
cat > /etc/rsyslog.d/30-nftables.conf << 'EOF'
:msg, contains, \"NFT-\" /var/log/nftables.log
& stop
EOF

touch /var/log/nftables.log
systemctl restart rsyslog

# ── 서비스 시작 ───────────────────────────────
systemctl enable nftables suricata
systemctl start nftables
systemctl restart suricata

echo 'Security setup done'
systemctl is-active suricata nftables"

    ok "Security: nftables + Suricata 설치 완료"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 : Web - Apache + ModSecurity WAF + OWASP Juice Shop
# ─────────────────────────────────────────────────────────────────────────────
setup_web() {
    step "3/5 Web 서버 - Apache + ModSecurity + Juice Shop"

    remote "$WEB_EXT_IP" "$WEB_USER" "$WEB_USER" "
set -e
# ── 패키지 설치 ───────────────────────────────
apt-get update -q
apt-get install -y apache2 libapache2-mod-security2 modsecurity-crs docker.io curl rsyslog

# ── Apache 모듈 활성화 ────────────────────────
a2enmod security2 proxy proxy_http headers

# ── ModSecurity - DetectionOnly 모드 ─────────
cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
sed -i 's/SecRuleEngine On/SecRuleEngine DetectionOnly/' /etc/modsecurity/modsecurity.conf
sed -i 's/SecAuditEngine RelevantOnly/SecAuditEngine On/' /etc/modsecurity/modsecurity.conf

# Apache security2 모듈 설정 (CRS 포함)
cat > /etc/apache2/mods-available/security2.conf << 'EOF'
<IfModule security2_module>
    SecDataDir /var/cache/modsecurity
    IncludeOptional /etc/modsecurity/modsecurity.conf
    Include /usr/share/modsecurity-crs/owasp-crs.load
</IfModule>
EOF
mkdir -p /var/cache/modsecurity
chown www-data:www-data /var/cache/modsecurity

# ── Juice Shop (Docker) ───────────────────────
systemctl enable docker
systemctl start docker
docker pull bkimminich/juice-shop:latest
docker rm -f juiceshop 2>/dev/null || true
docker run -d --name juiceshop --restart unless-stopped -p 3000:3000 bkimminich/juice-shop

# Juice Shop 기동 대기
for i in \$(seq 1 30); do
    curl -sf http://127.0.0.1:3000/ -o /dev/null && break
    sleep 2
done

# ── Apache 리버스 프록시 VHost ─────────────────
cat > /etc/apache2/sites-available/juiceshop.conf << 'EOF'
<VirtualHost *:80>
    ServerName web.internal

    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/

    Header always set X-WAF \"ModSecurity DetectionOnly\"

    ErrorLog  \${APACHE_LOG_DIR}/juiceshop_error.log
    CustomLog \${APACHE_LOG_DIR}/juiceshop_access.log combined
</VirtualHost>
EOF

a2dissite 000-default 2>/dev/null || true
a2ensite juiceshop
systemctl enable apache2
systemctl restart apache2

echo 'Web setup done'
systemctl is-active apache2
curl -sf -o /dev/null -w 'Juice Shop HTTP: %{http_code}' http://127.0.0.1/"

    ok "Web: Apache + ModSecurity + Juice Shop 설치 완료"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 : SIEM - Wazuh 올인원 설치
# ─────────────────────────────────────────────────────────────────────────────
setup_siem() {
    step "4/5 SIEM - Wazuh 4.7.x 설치 (10~15분 소요)"
    info "Wazuh Manager + Indexer + Dashboard 설치 중..."

    remote "$SIEM_EXT_IP" "$SIEM_USER" "$SIEM_USER" "
set -e
apt-get install -y curl
cd /tmp

# 이미 설치되어 있으면 스킵
if systemctl is-active wazuh-manager &>/dev/null; then
    echo 'Wazuh already installed and running'
    exit 0
fi

curl -sO https://packages.wazuh.com/4.7/wazuh-install.sh
bash wazuh-install.sh -a -i 2>&1 | tee /tmp/wazuh-install.log | tail -5

# syslog 수신 포트 설정 추가
LINE=\$(grep -n '</ossec_config>' /var/ossec/etc/ossec.conf | head -1 | cut -d: -f1)
head -n \$((\$LINE - 1)) /var/ossec/etc/ossec.conf > /tmp/ossec_tmp.conf
cat >> /tmp/ossec_tmp.conf << 'XMLEOF'

  <!-- 내부망 syslog 수신 (nftables, Apache 직접 전송용) -->
  <remote>
    <connection>syslog</connection>
    <port>514</port>
    <protocol>udp</protocol>
    <allowed-ips>${INTERNAL_NET}</allowed-ips>
  </remote>

</ossec_config>
XMLEOF
cp /tmp/ossec_tmp.conf /var/ossec/etc/ossec.conf
systemctl restart wazuh-manager
echo 'SIEM setup done'
systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard"

    ok "SIEM: Wazuh 설치 완료"
    info "비밀번호 확인: ssh ${SIEM_USER}@${SIEM_EXT_IP} 'sudo cat /tmp/wazuh-install-files.tar | tar xO ./wazuh-passwords.txt 2>/dev/null'"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 : Wazuh 에이전트 설치 + 로그 수집 설정
# ─────────────────────────────────────────────────────────────────────────────
setup_agents() {
    step "5/5 Wazuh 에이전트 설치 및 로그 수집 설정"

    # ── Security 에이전트 (Suricata + nftables 로그) ─────
    info "Security 에이전트 설치 중..."
    remote "$SECURITY_EXT_IP" "$SECURITY_USER" "$SECURITY_USER" "
set -e
# Wazuh 저장소 설정
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH -o /tmp/wazuh.key
gpg --dearmor < /tmp/wazuh.key > /usr/share/keyrings/wazuh.gpg
echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' > /etc/apt/sources.list.d/wazuh.list
apt-get update -q

# 4.7.5 버전 직접 다운로드 (매니저 버전과 일치)
curl -sO https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.7.5-1_amd64.deb
DEBIAN_FRONTEND=noninteractive dpkg -i --force-confnew /tmp/wazuh-agent_4.7.5-1_amd64.deb
systemctl daemon-reload

# ossec.conf - Suricata + nftables 로그 수집 설정
cat > /var/ossec/etc/ossec.conf << 'XMLEOF'
<ossec_config>
  <client>
    <server>
      <address>${SIEM_INT_IP}</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <notify_time>10</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
  </client>

  <!-- Suricata 이벤트 로그 (EVE JSON) -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>

  <!-- Suricata 알람 로그 -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/suricata/fast.log</location>
  </localfile>

  <!-- nftables 방화벽 로그 -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/nftables.log</location>
  </localfile>

  <!-- 시스템 로그 -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

  <syscheck>
    <frequency>300</frequency>
    <scan_on_start>yes</scan_on_start>
    <directories>/etc,/usr/bin,/usr/sbin</directories>
  </syscheck>

  <rootcheck>
    <disabled>no</disabled>
  </rootcheck>

  <active-response>
    <disabled>yes</disabled>
  </active-response>
</ossec_config>
XMLEOF

# 매니저에 에이전트 등록
systemctl enable wazuh-agent
/var/ossec/bin/agent-auth -m ${SIEM_INT_IP} -A security-vm
systemctl start wazuh-agent
sleep 2
systemctl is-active wazuh-agent"
    ok "Security 에이전트 등록 완료"

    # ── Web 에이전트 (ModSecurity + Apache 로그) ──────────
    info "Web 에이전트 설치 중..."
    remote "$WEB_EXT_IP" "$WEB_USER" "$WEB_USER" "
set -e
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH -o /tmp/wazuh.key
gpg --dearmor < /tmp/wazuh.key > /usr/share/keyrings/wazuh.gpg
echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' > /etc/apt/sources.list.d/wazuh.list
apt-get update -q

curl -sO https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.7.5-1_amd64.deb
DEBIAN_FRONTEND=noninteractive dpkg -i --force-confnew /tmp/wazuh-agent_4.7.5-1_amd64.deb
systemctl daemon-reload

# ossec.conf - ModSecurity + Apache 로그 수집 설정
cat > /var/ossec/etc/ossec.conf << 'XMLEOF'
<ossec_config>
  <client>
    <server>
      <address>${SIEM_INT_IP}</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <notify_time>10</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
  </client>

  <!-- ModSecurity WAF 감사 로그 -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/apache2/modsec_audit.log</location>
  </localfile>

  <!-- Apache Juice Shop 접근 로그 -->
  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/juiceshop_access.log</location>
  </localfile>

  <!-- Apache 에러 로그 -->
  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/error.log</location>
  </localfile>

  <!-- 시스템 로그 -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

  <syscheck>
    <frequency>300</frequency>
    <scan_on_start>yes</scan_on_start>
    <directories>/etc,/var/www,/usr/bin</directories>
  </syscheck>

  <rootcheck>
    <disabled>no</disabled>
  </rootcheck>

  <active-response>
    <disabled>yes</disabled>
  </active-response>
</ossec_config>
XMLEOF

systemctl enable wazuh-agent
/var/ossec/bin/agent-auth -m ${SIEM_INT_IP} -A web-vm
systemctl start wazuh-agent
sleep 2
systemctl is-active wazuh-agent"
    ok "Web 에이전트 등록 완료"
}

# ─────────────────────────────────────────────────────────────────────────────
# 최종 검증
# ─────────────────────────────────────────────────────────────────────────────
verify() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  최종 검증${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Juice Shop 응답 확인
    sleep 5
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 5 http://${WEB_INT_IP}/ 2>/dev/null || echo "000")
    [ "$HTTP" = "200" ] && ok "Juice Shop 응답: HTTP $HTTP" || warn "Juice Shop 응답: HTTP $HTTP"

    # Wazuh 대시보드 응답 확인
    HTTP=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 10 https://${SIEM_INT_IP}/ 2>/dev/null || echo "000")
    [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ] && ok "Wazuh Dashboard 응답: HTTP $HTTP" || warn "Wazuh Dashboard 응답: HTTP $HTTP"

    # 연결된 에이전트 수 확인
    AGENTS=$(sshpass -p "$SIEM_USER" ssh $SSH_OPTS "${SIEM_USER}@${SIEM_EXT_IP}" \
        "echo '$SIEM_USER' | sudo -S /var/ossec/bin/agent_control -l 2>/dev/null" 2>/dev/null | grep "Active" | grep -v Local | wc -l)
    [ "$AGENTS" -ge 2 ] && ok "Wazuh 에이전트 연결: ${AGENTS}개" || warn "Wazuh 에이전트 연결: ${AGENTS}개 (2개 이상 필요)"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        Purple Team Lab 구성 완료!                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Juice Shop (공격 대상):  http://${WEB_EXT_IP}/"
    echo "  Wazuh SIEM Dashboard:   https://${SIEM_EXT_IP}/"
    echo "  Wazuh 계정:             admin / (설치 로그 확인)"
    echo ""
    echo "  비밀번호 확인:"
    echo "    ssh ${SIEM_USER}@${SIEM_EXT_IP}"
    echo "    sudo tar -O -xf /tmp/wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt"
    echo ""
    echo "  유용한 스크립트:"
    echo "    ./scripts/check-status.sh   # 전체 상태 확인"
    echo "    ./scripts/test-attack.sh    # 공격 테스트 실행"
    echo "    ./scripts/view-logs.sh all  # 실시간 로그 모니터링"
}

# ─────────────────────────────────────────────────────────────────────────────
# 도움말
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    echo "사용법: $0 [옵션]"
    echo ""
    echo "옵션:"
    echo "  (없음)        전체 설치 실행"
    echo "  --network     STEP 1 만 실행 (네트워크 설정)"
    echo "  --security    STEP 2 만 실행 (nftables + Suricata)"
    echo "  --web         STEP 3 만 실행 (Apache + WAF + Juice Shop)"
    echo "  --siem        STEP 4 만 실행 (Wazuh 설치)"
    echo "  --agents      STEP 5 만 실행 (Wazuh 에이전트)"
    echo "  --verify      최종 검증만 실행"
    echo "  --help        이 도움말 출력"
    echo ""
    echo "IP 설정 변경 방법:"
    echo "  스크립트 상단 [설정] 섹션의 변수를 수정하세요."
    echo ""
    echo "예시 (개별 실행):"
    echo "  $0 --web       # Web 서버만 재설치"
    echo "  $0 --agents    # 에이전트만 재등록"
}

# ─────────────────────────────────────────────────────────────────────────────
# 메인
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${CYAN}"
echo "  ██████╗ ██╗   ██╗██████╗ ██████╗ ██╗     ███████╗"
echo "  ██╔══██╗██║   ██║██╔══██╗██╔══██╗██║     ██╔════╝"
echo "  ██████╔╝██║   ██║██████╔╝██████╔╝██║     █████╗  "
echo "  ██╔═══╝ ██║   ██║██╔══██╗██╔═══╝ ██║     ██╔══╝  "
echo "  ██║     ╚██████╔╝██║  ██║██║     ███████╗███████╗"
echo "  ╚═╝      ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝"
echo "  Team Lab - 자동 배포 스크립트"
echo -e "${NC}"

case "${1:-}" in
    --help)    usage ;;
    --network) preflight; setup_network ;;
    --security)preflight; setup_security ;;
    --web)     preflight; setup_web ;;
    --siem)    preflight; setup_siem ;;
    --agents)  preflight; setup_agents ;;
    --verify)  verify ;;
    "")
        preflight
        setup_network
        setup_security
        setup_web
        setup_siem
        setup_agents
        verify
        ;;
    *)
        err "알 수 없는 옵션: $1"
        usage
        exit 1
        ;;
esac
