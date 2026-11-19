#!/usr/bin/env bash
# AlertaChuva · gera evidências técnicas em texto dentro de evidencias/.
# Uso: sudo bash scripts/coletar_evidencias.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
exigir_root
set -uo pipefail

EVID="$RAIZ/evidencias"
mkdir -p "$EVID"

secao() {
    local arquivo="$1"; shift
    {
        echo "# AlertaChuva · evidência gerada em $(date '+%Y-%m-%d %H:%M:%S %z') no host $(hostname)"
        while (( $# )); do
            echo; echo "\$ $1"; bash -c "$1" 2>&1; shift
        done
    } > "$EVID/$arquivo"
    echo "gerado: $EVID/$arquivo"
}

secao 01_sistema_e_rede.txt \
    "cat /etc/os-release | head -4; uname -r" \
    "hostname; hostname -f" \
    "ip -br addr" \
    "ip route" \
    "cat /etc/hosts" \
    "cat /etc/resolv.conf" \
    "cat /etc/wsl.conf 2>/dev/null || echo 'sem /etc/wsl.conf (não é WSL)'" \
    "sysctl net.core.somaxconn net.ipv4.tcp_syncookies net.ipv4.tcp_fin_timeout" \
    "getent hosts ${DOMINIO} api.${DOMINIO} ${HOSTNAME_ALVO} github.com" \
    "dig +short ${DOMINIO} @127.0.0.1 2>/dev/null; nslookup github.com | tail -4"

secao 02_usuarios_e_permissoes.txt \
    "id ${APP_USUARIO}; id ${MON_USUARIO}; id ${OPERADOR}" \
    "getent passwd ${APP_USUARIO} ${MON_USUARIO} ${OPERADOR}" \
    "getent group ${GRUPO_OPS} ${APP_USUARIO}" \
    "cat /etc/sudoers.d/alertachuva" \
    "ls -ld ${APP_DIR} ${APP_DIR}/* ${CONF_DIR} ${CONF_DIR}/* ${LOG_DIR} ${LOG_DIR}/* ${ESTADO_DIR}" \
    "runuser -u ${OPERADOR} -- sudo -l -n 2>&1 | tail -n 12" \
    "runuser -u ${APP_USUARIO} -- cat ${CONF_DIR}/monitor.env 2>&1 || true"

secao 03_servicos_systemd.txt \
    "systemctl list-unit-files 'alertachuva*' nginx.service --no-pager" \
    "systemctl status alertachuva-rede alertachuva alertachuva-monitor nginx --no-pager -n 5" \
    "systemctl show alertachuva-monitor -p Restart -p RestartUSec -p NRestarts -p User -p MainPID" \
    "systemctl show alertachuva -p Restart -p NRestarts -p User -p MainPID" \
    "cat /etc/systemd/system/alertachuva.service /etc/systemd/system/alertachuva-monitor.service /etc/systemd/system/alertachuva-rede.service"

secao 04_aplicacao.txt \
    "curl --noproxy '*' -sS http://${DOMINIO}/api/saude | jq ." \
    "curl --noproxy '*' -sS http://${DOMINIO}/api/info | jq ." \
    "curl --noproxy '*' -sS 'http://${IP_SERVICO}/api/risco?data=2025-01-24' | jq ." \
    "curl --noproxy '*' -sS -o /dev/null -w 'página do morador: HTTP %{http_code} em %{time_total}s\n' http://localhost/" \
    "curl --noproxy '*' -sS -I http://${DOMINIO}/ | head -8" \
    "ss -ltnp | grep -E ':80 |:${APP_PORTA} '"

secao 05_monitoramento.txt \
    "runuser -u ${MON_USUARIO} -- ${APP_DIR}/bin/monitor.sh --uma-vez; echo \"código: \$?\"" \
    "tail -n 20 ${LOG_DIR}/monitor.log" \
    "tail -n 20 ${LOG_DIR}/alertas.log" \
    "tail -n 15 ${LOG_DIR}/metricas.csv"

secao 06_logs_e_auditoria.txt \
    "ls -l ${LOG_DIR} ${LOG_DIR}/app" \
    "tail -n 40 ${LOG_DIR}/auditoria.log" \
    "grep -E 'INÍCIO|OK|ERRO' ${LOG_DIR}/provisionamento.log | tail -n 40" \
    "tail -n 20 ${LOG_DIR}/erros.log" \
    "tail -n 15 ${LOG_DIR}/app/app.log" \
    "tail -n 10 /var/log/nginx/alertachuva_acesso.log" \
    "journalctl -t alertachuva -n 15 --no-pager" \
    "journalctl -u alertachuva-monitor -u alertachuva -n 25 --no-pager"

secao 07_validacao.txt "bash $DIR/validar.sh"

[[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER": "$EVID"
auditar "coletar evidências" OK "$EVID"
