# Security Test Platform - Purple Team Lab

교육 목적의 Red/Blue Team 퍼플팀 실습 환경입니다.  
VMware 기반 4개의 리눅스 서버로 구성된 보안 시스템 구현 환경으로, 공격과 방어를 동시에 실습할 수 있습니다.

---

## 아키텍처

```
┌─────────────────────────────────────────────────────────┐
│                   192.168.193.0/24 (External)           │
│                                                         │
│  [Agent]──────[Security]──────[Web]──────[SIEM]         │
│  .129           .131           .130        .132         │
└─────────────────────────────────────────────────────────┘
                         │
┌─────────────────────────────────────────────────────────┐
│                    10.10.10.0/24 (Internal)             │
│                                                         │
│  [Agent]         [Security]    [Web]       [SIEM]       │
│  .100         →    .1    →     .80          .50         │
│                (Gateway/IPS)                            │
└─────────────────────────────────────────────────────────┘

Traffic Flow: Agent → nftables(Security) → Suricata(Security) → Web
Log Flow:     Security/Web → Wazuh Agent → SIEM(Wazuh Manager)
```

---

## VM 구성

### 1. Agent (Red Team) - 192.168.193.129 / 10.10.10.100
| 항목 | 내용 |
|------|------|
| OS | Ubuntu 22.04.5 LTS |
| 역할 | AI 에이전트 엔드포인트, 모의 해킹 수행 |
| SSH | `ssh agent@192.168.193.129` (pw: agent) |
| 내부 IP | 10.10.10.100 (ens37) |

### 2. Security (Blue Team) - 192.168.193.131 / 10.10.10.1
| 항목 | 내용 |
|------|------|
| OS | Ubuntu 22.04.5 LTS |
| 역할 | 방화벽 + IPS 운영, 내부망 게이트웨이 |
| SSH | `ssh security@192.168.193.131` (pw: security) |
| 내부 IP | 10.10.10.1 (ens37) - 내부망 게이트웨이 |
| nftables | 방화벽 (FORWARD 로깅 포함) |
| Suricata | IPS 8.0.4 (DetectionOnly 모드, 65,394 규칙) |
| Wazuh | Agent 4.7.5 |

### 3. Web (Target) - 192.168.193.130 / 10.10.10.80
| 항목 | 내용 |
|------|------|
| OS | Ubuntu 22.04.5 LTS |
| 역할 | WAF + 취약 웹사이트 운영 |
| SSH | `ssh web@192.168.193.130` (pw: web) |
| 내부 IP | 10.10.10.80 (ens37) |
| Apache + ModSecurity | WAF (DetectionOnly 모드, OWASP CRS) |
| OWASP Juice Shop | 취약 웹 앱 (Docker, port 3000 → Apache proxy) |
| Wazuh | Agent 4.7.5 |

### 4. SIEM - 192.168.193.132 / 10.10.10.50
| 항목 | 내용 |
|------|------|
| OS | Ubuntu 22.04.5 LTS |
| 역할 | 로그 수집 및 분석, XDR 운영 |
| SSH | `ssh siem@192.168.193.132` (pw: siem) |
| 내부 IP | 10.10.10.50 (ens37) |
| Wazuh | Manager + Indexer + Dashboard 4.7.5 |
| Dashboard | https://192.168.193.132/ |

---

## 서비스 접속 정보

### OWASP Juice Shop (취약 웹사이트)
```
URL: http://192.168.193.130/
내부: http://10.10.10.80/
```
- OWASP Top 10 취약점 포함
- XSS, SQL Injection, IDOR, CSRF 등 실습 가능

### Wazuh SIEM Dashboard
```
URL:      https://192.168.193.132/
Username: admin
Password: (설치 시 자동 생성 - /tmp/wazuh-passwords.txt 참조)
API:      https://192.168.193.132:55000/
```

---

## 로그 수집 구조

```
[Security VM]
  /var/log/suricata/eve.json     ← Suricata 이벤트 (JSON)
  /var/log/suricata/fast.log     ← Suricata 알람
  /var/log/nftables.log          ← nftables 방화벽 로그
        │
        └──→ Wazuh Agent ──→ SIEM (10.10.10.50:1514)

[Web VM]
  /var/log/apache2/modsec_audit.log      ← ModSecurity WAF 감사 로그
  /var/log/apache2/juiceshop_access.log  ← Apache 접근 로그
  /var/log/apache2/error.log             ← Apache 에러 로그
        │
        └──→ Wazuh Agent ──→ SIEM (10.10.10.50:1514)

[SIEM]
  Wazuh Manager (포트 1514)  ← 에이전트 로그 수신
  Wazuh Indexer  (포트 9200) ← 로그 저장 (OpenSearch)
  Wazuh Dashboard (포트 443) ← 시각화 및 분석
  Syslog (포트 514 UDP)      ← 직접 syslog 수신
```

---

## 네트워크 설정

### 내부망 IP 설정 (모든 VM - /etc/netplan/99-internal.yaml)

**Security (게이트웨이)**
```yaml
network:
  version: 2
  ethernets:
    ens37:
      addresses:
        - 10.10.10.1/24
```

**Agent / Web / SIEM (라우팅 포함)**
```yaml
network:
  version: 2
  ethernets:
    ens37:
      addresses:
        - 10.10.10.X/24
      routes:
        - to: 10.10.10.0/24
          via: 10.10.10.1
          metric: 100
```

### IP Forwarding (Security)
```bash
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.ens37.send_redirects=0
```

---

## 설치된 소프트웨어

### Security VM
```bash
# Suricata 설치
add-apt-repository ppa:oisf/suricata-stable
apt-get install -y suricata nftables

# 규칙 업데이트
suricata-update
```

### Web VM
```bash
# Apache + ModSecurity 설치
apt-get install -y apache2 libapache2-mod-security2 modsecurity-crs docker.io

# Apache 모듈 활성화
a2enmod security2 proxy proxy_http headers

# Juice Shop (Docker)
docker run -d --name juiceshop --restart unless-stopped -p 3000:3000 bkimminich/juice-shop
```

### SIEM VM
```bash
# Wazuh 올인원 설치 (Manager + Indexer + Dashboard)
curl -sO https://packages.wazuh.com/4.7/wazuh-install.sh
bash wazuh-install.sh -a -i
```

### Agent 등록 (Security/Web VM)
```bash
# Wazuh 에이전트 설치
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor > /usr/share/keyrings/wazuh.gpg
echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' > /etc/apt/sources.list.d/wazuh.list
WAZUH_MANAGER=10.10.10.50 apt-get install -y wazuh-agent=4.7.5-1

# 에이전트 등록
/var/ossec/bin/agent-auth -m 10.10.10.50 -A <agent-name>
systemctl enable --now wazuh-agent
```

---

## 설정 파일 위치

| 서비스 | 설정 파일 |
|--------|-----------|
| Suricata | `/etc/suricata/suricata.yaml` |
| Suricata 규칙 | `/var/lib/suricata/rules/suricata.rules` |
| nftables | `/etc/nftables.conf` |
| ModSecurity | `/etc/modsecurity/modsecurity.conf` |
| ModSecurity CRS | `/etc/modsecurity/crs/crs-setup.conf` |
| Apache VHost | `/etc/apache2/sites-available/juiceshop.conf` |
| Wazuh Manager | `/var/ossec/etc/ossec.conf` |
| Wazuh Agent | `/var/ossec/etc/ossec.conf` |

---

## 모의 해킹 실습 가이드

### 1. 공격 대상 확인
```bash
# Agent VM에서 Juice Shop 접근
curl http://10.10.10.80/
```

### 2. 기본 취약점 테스트

**SQL Injection**
```bash
curl "http://10.10.10.80/rest/products/search?q=')) OR 1=1--"
```

**XSS (Cross-Site Scripting)**
```bash
curl "http://10.10.10.80/?q=<script>alert('XSS')</script>"
```

**Path Traversal**
```bash
curl "http://10.10.10.80/../../../../etc/passwd"
```

### 3. 탐지 확인 (SIEM)
- Wazuh 대시보드: https://192.168.193.132/
- Security Events → 실시간 알람 확인
- Suricata 탐지: `cat /var/log/suricata/fast.log`
- ModSecurity 탐지: `cat /var/log/apache2/modsec_audit.log`

### 4. Nmap 스캐닝
```bash
# Agent VM에서 실행
sudo apt install -y nmap
nmap -sV -O 10.10.10.80
```

---

## 운영 모드 변경

### Suricata - 차단 모드 활성화 (NFQUEUE)
```bash
# /etc/suricata/suricata.yaml에서 변경
# nfq 섹션 활성화 후 재시작
# nftables에서 NFQUEUE로 전달 설정 필요
```

### ModSecurity - 차단 모드 활성화
```bash
# /etc/modsecurity/modsecurity.conf 수정
sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/modsecurity/modsecurity.conf
systemctl restart apache2
```

---

## 트러블슈팅

### Suricata 상태 확인
```bash
ssh security@192.168.193.131
sudo systemctl status suricata
sudo tail -f /var/log/suricata/suricata.log
sudo tail -f /var/log/suricata/fast.log
```

### Wazuh 에이전트 연결 확인
```bash
# SIEM에서 에이전트 목록
ssh siem@192.168.193.132
sudo /var/ossec/bin/agent_control -l

# 에이전트에서 연결 상태
sudo grep -i "connected" /var/ossec/logs/ossec.log | tail -5
```

### nftables 로그 확인
```bash
ssh security@192.168.193.131
sudo tail -f /var/log/nftables.log
sudo nft list ruleset
```

### Juice Shop 재시작
```bash
ssh web@192.168.193.130
sudo docker restart juiceshop
sudo docker logs juiceshop --tail 20
```

---

## 참고 자료

- [OWASP Juice Shop](https://owasp.org/www-project-juice-shop/)
- [Suricata Documentation](https://suricata.readthedocs.io/)
- [ModSecurity Reference Manual](https://github.com/SpiderLabs/ModSecurity/wiki)
- [Wazuh Documentation](https://documentation.wazuh.com/)
- [OWASP CRS Documentation](https://coreruleset.org/docs/)
- [nftables Wiki](https://wiki.nftables.org/)

---

## 주의사항

> **이 환경은 교육 전용입니다.**  
> 모든 공격 기법은 이 격리된 실습 환경 내에서만 사용하세요.  
> 허가되지 않은 시스템에 대한 공격은 불법입니다.
