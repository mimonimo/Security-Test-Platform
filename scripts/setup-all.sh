#!/bin/bash
# =============================================================================
# Purple Team Lab - Full Setup Script
# 4개 VMware 서버에 보안 환경을 자동으로 구성합니다.
# 교육 목적으로만 사용하세요.
# =============================================================================

set -e

# ─────────────────────────────────────────────
# 색상 및 출력 함수
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─────────────────────────────────────────────
# 접속 정보
# ─────────────────────────────────────────────
AGENT_IP="192.168.193.129"
SECURITY_IP="192.168.193.131"
WEB_IP="192.168.193.130"
SIEM_IP="192.168.193.132"

AGENT_USER="agent"
SECURITY_USER="security"
WEB_USER="web"
SIEM_USER="siem"

# sshpass 필요
command -v sshpass &>/dev/null || sudo apt-get install -y sshpass

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

ssh_run() {
    local host=$1
    local user=$2
    local pass=$3
    local cmd=$4
    sshpass -p "$pass" ssh $SSH_OPTS "${user}@${host}" "echo '$pass' | sudo -S bash -c '$cmd'" 2>&1
}

# ─────────────────────────────────────────────
# STEP 1: 내부 네트워크 IP 설정
# ─────────────────────────────────────────────
info "STEP 1: 내부 네트워크 IP 설정 (10.10.10.0/24)"

# Agent: 10.10.10.100
sudo bash -c 'cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ens37:
      addresses:
        - 10.10.10.100/24
      routes:
        - to: 10.10.10.0/24
          via: 10.10.10.1
          metric: 100
EOF
chmod 600 /etc/netplan/99-internal.yaml
netplan apply'
success "Agent: 10.10.10.100 설정 완료"

# Security: 10.10.10.1 (Gateway)
sshpass -p "$SECURITY_USER" ssh $SSH_OPTS "${SECURITY_USER}@${SECURITY_IP}" "echo '$SECURITY_USER' | sudo -S bash -c '
chmod 600 /etc/netplan/*.yaml 2>/dev/null
cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ens37:
      addresses:
        - 10.10.10.1/24
EOF
chmod 600 /etc/netplan/99-internal.yaml
echo \"net.ipv4.ip_forward=1\" >> /etc/sysctl.conf
echo \"net.ipv4.conf.all.send_redirects=0\" >> /etc/sysctl.conf
sysctl -p
netplan apply'"
success "Security: 10.10.10.1 설정 완료 (IP forwarding 활성화)"

# Web: 10.10.10.80
sshpass -p "$WEB_USER" ssh $SSH_OPTS "${WEB_USER}@${WEB_IP}" "echo '$WEB_USER' | sudo -S bash -c '
chmod 600 /etc/netplan/*.yaml 2>/dev/null
cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ens37:
      addresses:
        - 10.10.10.80/24
      routes:
        - to: 10.10.10.0/24
          via: 10.10.10.1
          metric: 100
EOF
chmod 600 /etc/netplan/99-internal.yaml
netplan apply'"
success "Web: 10.10.10.80 설정 완료"

# SIEM: 10.10.10.50
sshpass -p "$SIEM_USER" ssh $SSH_OPTS "${SIEM_USER}@${SIEM_IP}" "echo '$SIEM_USER' | sudo -S bash -c '
chmod 600 /etc/netplan/*.yaml 2>/dev/null
cat > /etc/netplan/99-internal.yaml << EOF
network:
  version: 2
  ethernets:
    ens37:
      addresses:
        - 10.10.10.50/24
      routes:
        - to: 10.10.10.0/24
          via: 10.10.10.1
          metric: 100
EOF
chmod 600 /etc/netplan/99-internal.yaml
netplan apply'"
success "SIEM: 10.10.10.50 설정 완료"

# ─────────────────────────────────────────────
# STEP 2: Security - nftables + Suricata 설치
# ─────────────────────────────────────────────
info "STEP 2: Security 서버 - nftables + Suricata 설치"

sshpass -p "$SECURITY_USER" ssh $SSH_OPTS "${SECURITY_USER}@${SECURITY_IP}" "echo '$SECURITY_USER' | sudo -S bash -c '
# Suricata 설치
add-apt-repository -y ppa:oisf/suricata-stable
apt-get update -q
apt-get install -y suricata nftables curl

# Suricata HOME_NET 설정
sed -i \"s|HOME_NET: \\\"\[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12\]\\\"|HOME_NET: \\\"[10.10.10.0/24]\\\"|\" /etc/suricata/suricata.yaml
# Interface 설정
sed -i \"s/interface: eth0/interface: ens37/\" /etc/suricata/suricata.yaml

# 규칙 업데이트
suricata-update

# nftables 설정
cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        iif lo accept
        ct state established,related accept
        tcp dport 22 accept
        ip protocol icmp accept
        iif ens37 ip saddr 10.10.10.0/24 accept
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
        oif ens33 ip saddr 10.10.10.0/24 masquerade
    }
}
NFTEOF

# rsyslog for nftables
cat > /etc/rsyslog.d/30-nftables.conf << EOF
:msg, contains, \"NFT-\" /var/log/nftables.log
& stop
EOF

# 서비스 시작
nft -f /etc/nftables.conf
systemctl enable nftables suricata
systemctl restart rsyslog
systemctl start suricata nftables
'"
success "Security: nftables + Suricata 설치 완료"

# ─────────────────────────────────────────────
# STEP 3: Web - Apache + ModSecurity + Juice Shop
# ─────────────────────────────────────────────
info "STEP 3: Web 서버 - Apache + ModSecurity + OWASP Juice Shop 설치"

sshpass -p "$WEB_USER" ssh $SSH_OPTS "${WEB_USER}@${WEB_IP}" "echo '$WEB_USER' | sudo -S bash -c '
# 설치
apt-get update -q
apt-get install -y apache2 libapache2-mod-security2 modsecurity-crs docker.io curl

# Apache 모듈 활성화
a2enmod security2 proxy proxy_http headers

# ModSecurity DetectionOnly 모드
cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
sed -i \"s/SecRuleEngine On/SecRuleEngine DetectionOnly/\" /etc/modsecurity/modsecurity.conf

# Apache modsecurity 설정
cat > /etc/apache2/mods-available/security2.conf << EOF
<IfModule security2_module>
    SecDataDir /var/cache/modsecurity
    IncludeOptional /etc/modsecurity/modsecurity.conf
    Include /usr/share/modsecurity-crs/owasp-crs.load
</IfModule>
EOF
mkdir -p /var/cache/modsecurity
chown www-data:www-data /var/cache/modsecurity

# Juice Shop Docker
systemctl start docker
docker pull bkimminich/juice-shop:latest
docker run -d --name juiceshop --restart unless-stopped -p 3000:3000 bkimminich/juice-shop
sleep 5

# Apache 리버스 프록시 VHost
cat > /etc/apache2/sites-available/juiceshop.conf << EOF
<VirtualHost *:80>
    ServerName web.internal
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/
    ErrorLog \\\${APACHE_LOG_DIR}/juiceshop_error.log
    CustomLog \\\${APACHE_LOG_DIR}/juiceshop_access.log combined
</VirtualHost>
EOF

a2dissite 000-default
a2ensite juiceshop
systemctl enable apache2
systemctl restart apache2
'"
success "Web: Apache + ModSecurity + Juice Shop 설치 완료"

# ─────────────────────────────────────────────
# STEP 4: SIEM - Wazuh 올인원 설치
# ─────────────────────────────────────────────
info "STEP 4: SIEM - Wazuh 설치 (10-15분 소요)"

sshpass -p "$SIEM_USER" ssh $SSH_OPTS "${SIEM_USER}@${SIEM_IP}" "echo '$SIEM_USER' | sudo -S bash -c '
cd /tmp
apt-get install -y curl
curl -sO https://packages.wazuh.com/4.7/wazuh-install.sh
bash wazuh-install.sh -a -i 2>&1 | tail -10
'"
success "SIEM: Wazuh Manager + Indexer + Dashboard 설치 완료"

# ─────────────────────────────────────────────
# STEP 5: Wazuh 에이전트 설치 (Security + Web)
# ─────────────────────────────────────────────
info "STEP 5: Wazuh 에이전트 설치"

for SERVER_INFO in "${SECURITY_USER}:${SECURITY_IP}:security-agent" "${WEB_USER}:${WEB_IP}:web-agent"; do
    USER=$(echo $SERVER_INFO | cut -d: -f1)
    IP=$(echo $SERVER_INFO | cut -d: -f2)
    AGENT_NAME=$(echo $SERVER_INFO | cut -d: -f3)

    sshpass -p "$USER" ssh $SSH_OPTS "${USER}@${IP}" "echo '$USER' | sudo -S bash -c '
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH -o /tmp/wazuh.key
gpg --dearmor < /tmp/wazuh.key > /usr/share/keyrings/wazuh.gpg
echo \"deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main\" > /etc/apt/sources.list.d/wazuh.list
apt-get update -q
curl -sO https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.7.5-1_amd64.deb
DEBIAN_FRONTEND=noninteractive dpkg -i --force-confnew /tmp/wazuh-agent_4.7.5-1_amd64.deb
systemctl daemon-reload
systemctl enable wazuh-agent
/var/ossec/bin/agent-auth -m 10.10.10.50 -A $AGENT_NAME
systemctl start wazuh-agent
'"
    success "에이전트 설치: $AGENT_NAME ($IP)"
done

info "설치 완료! Wazuh 대시보드: https://${SIEM_IP}/"
echo ""
echo "비밀번호 확인: ssh ${SIEM_USER}@${SIEM_IP} 'sudo cat /tmp/wazuh-passwords.txt'"
