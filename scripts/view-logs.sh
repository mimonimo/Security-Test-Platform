#!/bin/bash
# =============================================================================
# Purple Team Lab - 실시간 로그 모니터링
# =============================================================================

command -v sshpass &>/dev/null || sudo apt-get install -y sshpass

usage() {
    echo "사용법: $0 [옵션]"
    echo ""
    echo "옵션:"
    echo "  suricata     Suricata 알람 로그 (fast.log)"
    echo "  suricata-eve Suricata EVE JSON 로그"
    echo "  modsec       ModSecurity WAF 감사 로그"
    echo "  apache       Apache 접근 로그"
    echo "  nftables     nftables 방화벽 로그"
    echo "  wazuh        Wazuh 에이전트 로그 (security)"
    echo "  all          모든 로그 동시 모니터링 (tmux 필요)"
    echo ""
    echo "예시:"
    echo "  $0 suricata"
    echo "  $0 modsec"
}

case "$1" in
    suricata)
        echo "[Security VM] Suricata 알람 로그 모니터링..."
        sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 \
            "echo security | sudo -S tail -f /var/log/suricata/fast.log"
        ;;
    suricata-eve)
        echo "[Security VM] Suricata EVE JSON 로그..."
        sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 \
            "echo security | sudo -S tail -f /var/log/suricata/eve.json | python3 -c '
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get(\"event_type\") == \"alert\":
            print(f\"[{e.get(\"timestamp\",\"\")[:19]}] ALERT: {e.get(\"alert\",{}).get(\"signature\",\"?\")} | {e.get(\"src_ip\",\"?\")} → {e.get(\"dest_ip\",\"?\")}:{e.get(\"dest_port\",\"?\")}\"  )
    except:
        pass'"
        ;;
    modsec)
        echo "[Web VM] ModSecurity WAF 감사 로그..."
        sshpass -p web ssh -o StrictHostKeyChecking=no web@192.168.193.130 \
            "echo web | sudo -S tail -f /var/log/apache2/modsec_audit.log"
        ;;
    apache)
        echo "[Web VM] Apache 접근 로그..."
        sshpass -p web ssh -o StrictHostKeyChecking=no web@192.168.193.130 \
            "echo web | sudo -S tail -f /var/log/apache2/juiceshop_access.log"
        ;;
    nftables)
        echo "[Security VM] nftables 방화벽 로그..."
        sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 \
            "echo security | sudo -S tail -f /var/log/nftables.log"
        ;;
    wazuh)
        echo "[Security VM] Wazuh 에이전트 로그..."
        sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 \
            "echo security | sudo -S tail -f /var/ossec/logs/ossec.log"
        ;;
    all)
        if command -v tmux &>/dev/null; then
            tmux new-session -d -s logs -x 220 -y 50
            tmux split-window -h -t logs
            tmux split-window -v -t logs:0.0
            tmux split-window -v -t logs:0.1

            tmux send-keys -t logs:0.0 "sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 'echo security | sudo -S tail -f /var/log/suricata/fast.log'" Enter
            tmux send-keys -t logs:0.1 "sshpass -p web ssh -o StrictHostKeyChecking=no web@192.168.193.130 'echo web | sudo -S tail -f /var/log/apache2/modsec_audit.log'" Enter
            tmux send-keys -t logs:0.2 "sshpass -p security ssh -o StrictHostKeyChecking=no security@192.168.193.131 'echo security | sudo -S tail -f /var/log/nftables.log'" Enter
            tmux send-keys -t logs:0.3 "sshpass -p web ssh -o StrictHostKeyChecking=no web@192.168.193.130 'echo web | sudo -S tail -f /var/log/apache2/juiceshop_access.log'" Enter

            tmux attach -t logs
        else
            echo "tmux가 설치되어 있지 않습니다: sudo apt install tmux"
        fi
        ;;
    *)
        usage
        ;;
esac
