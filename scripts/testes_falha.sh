#!/usr/bin/env bash
# AlertaChuva · testes de falha e recuperação. Cada teste salva sua evidência em so/evidencias/testes/.
# Uso: sudo bash so/scripts/testes_falha.sh [monitor|api|cpu|memoria|disco|script|reinicio-antes|reinicio-depois|todos]
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
LOG_ARQUIVO="testes.log"
exigir_root
preparar_log_dir
set -uo pipefail

EVID="$RAIZ/evidencias/testes"
mkdir -p "$EVID"
MONITOR="$APP_DIR/bin/monitor.sh"

titulo() { printf '\n==== %s ====\n' "$*"; }

resultado() {
    local teste="$1" ok="$2" detalhe="$3"
    if [[ "$ok" == 1 ]]; then
        log OK "TESTE ${teste}: PASSOU · ${detalhe}"
        auditar "teste de falha: ${teste}" OK "$detalhe"
    else
        log ERRO "TESTE ${teste}: NÃO PASSOU · ${detalhe}"
        auditar "teste de falha: ${teste}" FALHA "$detalhe"
    fi
}

linhas() { wc -l < "$1"; }
novas_linhas() { tail -n +"$(( $2 + 1 ))" "$1"; }
mostrar_novas() { echo "--- novas linhas em $1"; novas_linhas "$1" "$2"; }
como_monitor() { runuser -u "$MON_USUARIO" -- env "$@" "$MONITOR" --uma-vez; }

teste_monitor() {
    titulo "Interromper o serviço de monitoramento (kill -9) e verificar a recuperação"
    local pid1 pid2 ok=0
    pid1=$(systemctl show -p MainPID --value alertachuva-monitor.service)
    echo "PID antes: ${pid1}"
    kill -9 "$pid1"
    echo "kill -9 ${pid1} enviado às $(date '+%H:%M:%S'); aguardando o systemd (RestartSec=5)..."
    sleep 9
    pid2=$(systemctl show -p MainPID --value alertachuva-monitor.service)
    echo "PID depois: ${pid2} | estado: $(systemctl is-active alertachuva-monitor.service) | reinícios: $(systemctl show -p NRestarts --value alertachuva-monitor.service)"
    journalctl -u alertachuva-monitor.service --since "-1min" --no-pager | tail -n 8
    tail -n 3 "$LOG_DIR/monitor.log"
    [[ "$pid2" != "0" && "$pid2" != "$pid1" ]] && systemctl is-active --quiet alertachuva-monitor.service && ok=1
    resultado monitor "$ok" "pid ${pid1} -> ${pid2}"
}

teste_api() {
    titulo "Derrubar a API (kill -9 e parada) e verificar detecção e recuperação"
    local pid1 pid2 ok=0 i
    pid1=$(systemctl show -p MainPID --value alertachuva.service)
    echo "PID do Gunicorn antes: ${pid1}"
    kill -9 "$pid1"
    for i in $(seq 1 30); do
        sleep 1
        curl --noproxy '*' -fsS --max-time 2 "http://${DOMINIO}/api/saude" >/dev/null 2>&1 && break
    done
    pid2=$(systemctl show -p MainPID --value alertachuva.service)
    echo "API de volta em ~${i}s | PID depois: ${pid2} | reinícios: $(systemctl show -p NRestarts --value alertachuva.service)"
    curl --noproxy '*' -fsS "http://${DOMINIO}/api/saude"; echo
    echo; echo "Parada manual para o monitor detectar a falha:"
    systemctl stop alertachuva.service
    como_monitor
    echo "código de saída do monitor: $? (1 = alerta)"
    tail -n 2 "$LOG_DIR/erros.log"
    systemctl start alertachuva.service
    for i in $(seq 1 30); do sleep 1; curl --noproxy '*' -fsS --max-time 2 "http://${DOMINIO}/api/saude" >/dev/null 2>&1 && break; done
    como_monitor && echo "monitor: tudo normal"
    journalctl -u alertachuva.service --since "-2min" --no-pager | grep -E 'Started|Stopped|Main process|Booting|Listening' | tail -n 8
    [[ "$pid2" != "$pid1" ]] && curl --noproxy '*' -fsS --max-time 3 "http://${DOMINIO}/api/saude" >/dev/null && ok=1
    resultado api "$ok" "pid ${pid1} -> ${pid2}; parada detectada e serviço retomado"
}

teste_cpu() {
    titulo "Simular consumo elevado de CPU (stress-ng em todos os núcleos por 45s)"
    local antes ok=0
    antes=$(linhas "$LOG_DIR/alertas.log")
    echo "núcleos: $(nproc) | limite: ${CPU_LIMITE}% | intervalo do monitor: ${MONITOR_INTERVALO}s"
    stress-ng --cpu 0 --timeout 45s --metrics-brief
    sleep 2
    mostrar_novas "$LOG_DIR/alertas.log" "$antes"
    novas_linhas "$LOG_DIR/alertas.log" "$antes" | grep -q 'CPU' && ok=1
    tail -n 6 "$LOG_DIR/monitor.log"
    resultado cpu "$ok" "alertas de CPU gerados pelo serviço de monitoramento"
}

teste_memoria() {
    titulo "Simular consumo elevado de memória (ocupar a RAM até ${MEM_LIMITE}% + 8 pontos por 40s)"
    local antes ok=0
    antes=$(linhas "$LOG_DIR/alertas.log")
    free -h
    python3 - "$(( MEM_LIMITE + 8 ))" <<'PY' &
import sys, time
alvo = float(sys.argv[1])
def uso():
    m = dict(l.split(":") for l in open("/proc/meminfo"))
    t, a = int(m["MemTotal"].split()[0]), int(m["MemAvailable"].split()[0])
    return 100 * (t - a) / t, a
blocos = []
while True:
    u, livre = uso()
    if u >= alvo or livre < 300 * 1024:
        break
    blocos.append(b"\x01" * (128 * 1024 * 1024))
print(f"memória ocupada: {uso()[0]:.1f}% ({len(blocos) * 128} MiB alocados pelo teste)", flush=True)
time.sleep(40)
PY
    sleep 25; free -h; wait
    sleep 2
    mostrar_novas "$LOG_DIR/alertas.log" "$antes"
    novas_linhas "$LOG_DIR/alertas.log" "$antes" | grep -q 'MEMÓRIA' && ok=1
    resultado memoria "$ok" "alertas de memória gerados pelo serviço de monitoramento"
}

teste_disco() {
    titulo "Simular disco acima do limite (limite reduzido para 1% só nesta verificação)"
    local antes ok=0
    antes=$(linhas "$LOG_DIR/alertas.log")
    df -h / "$LOG_DIR"
    como_monitor DISCO_LIMITE=1
    mostrar_novas "$LOG_DIR/alertas.log" "$antes"
    novas_linhas "$LOG_DIR/alertas.log" "$antes" | grep -q 'DISCO' && ok=1
    resultado disco "$ok" "alerta de disco gerado com limite de teste de 1%"
}

teste_script() {
    titulo "Provocar falhas controladas em scripts e verificar o registro do erro"
    local antes rc ok=0
    antes=$(linhas "$LOG_DIR/erros.log")
    bash "$DIR/falha_controlada.sh"; rc=$?
    echo "falha_controlada.sh terminou com código ${rc}"
    como_monitor CPU_LIMITE=abc; echo "monitor com CPU_LIMITE=abc terminou com código $?"
    mostrar_novas "$LOG_DIR/erros.log" "$antes"
    (( rc != 0 )) && novas_linhas "$LOG_DIR/erros.log" "$antes" | grep -q 'falha_controlada.sh' \
        && novas_linhas "$LOG_DIR/erros.log" "$antes" | grep -q 'CPU_LIMITE' && ok=1
    resultado script "$ok" "erros capturados com linha, comando e código"
}

teste_reinicio_antes() {
    titulo "Preparar teste de reinicialização"
    install -d -m 0750 "$ESTADO_DIR"
    { cat /proc/sys/kernel/random/boot_id; date '+%Y-%m-%dT%H:%M:%S%z'; } > "$ESTADO_DIR/teste_reinicio"
    echo "boot atual: $(head -1 "$ESTADO_DIR/teste_reinicio") | uptime: $(uptime -p)"
    systemctl is-active alertachuva-rede alertachuva alertachuva-monitor nginx
    auditar "teste de falha: reinício (antes)" OK "boot_id salvo"
    if eh_wsl; then
        echo "Agora, no PowerShell do Windows: wsl --shutdown  · abra o Ubuntu e rode: sudo bash so/scripts/testes_falha.sh reinicio-depois"
    else
        echo "Agora rode: sudo reboot  · depois: sudo bash so/scripts/testes_falha.sh reinicio-depois"
    fi
}

teste_reinicio_depois() {
    titulo "Verificar serviços após a reinicialização"
    local antes atual ok=0 i
    [[ -r "$ESTADO_DIR/teste_reinicio" ]] || { echo "rode antes: testes_falha.sh reinicio-antes"; return 1; }
    antes=$(head -1 "$ESTADO_DIR/teste_reinicio")
    atual=$(cat /proc/sys/kernel/random/boot_id)
    echo "boot antes: ${antes}"; echo "boot agora: ${atual} | uptime: $(uptime -p) | hostname: $(hostname)"
    for i in $(seq 1 30); do curl --noproxy '*' -fsS --max-time 2 "http://${DOMINIO}/api/saude" >/dev/null 2>&1 && break; sleep 2; done
    systemctl is-active alertachuva-rede alertachuva alertachuva-monitor nginx
    ip -br addr | grep -F "$IP_SERVICO"
    curl --noproxy '*' -fsS "http://${DOMINIO}/api/saude"; echo
    journalctl --list-boots --no-pager | tail -n 3
    grep 'monitor iniciado' "$LOG_DIR/monitor.log" | tail -n 2
    [[ "$antes" != "$atual" ]] && systemctl is-active --quiet alertachuva alertachuva-monitor nginx alertachuva-rede && ok=1
    resultado reinicio "$ok" "novo boot e serviços iniciados automaticamente"
}

rodar() {
    local nome="$1" arq
    arq="$EVID/$(date +%Y%m%d_%H%M%S)_${nome}.txt"
    "teste_${nome//-/_}" 2>&1 | tee "$arq"
    [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER": "$RAIZ/evidencias" 2>/dev/null
    echo "evidência salva em ${arq}"
}

case "${1:-todos}" in
    monitor|api|cpu|memoria|disco|script|reinicio-antes|reinicio-depois) rodar "$1" ;;
    todos) for t in monitor api cpu memoria disco script; do rodar "$t"; done ;;
    *) echo "uso: $0 [monitor|api|cpu|memoria|disco|script|reinicio-antes|reinicio-depois|todos]" >&2; exit 2 ;;
esac
