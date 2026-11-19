#!/usr/bin/env bash
# Monitor AlertaChuva · CPU, memória RAM, disco e saúde da API, com alertas quando os limites são ultrapassados.
# Uso: monitor.sh --uma-vez   (uma verificação; sai com 1 se houver alerta)
#      monitor.sh --continuo  (laço periódico, usado pelo serviço alertachuva-monitor)
DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT_NOME="monitor.sh"
LOG_ARQUIVO="monitor.log"

carregar_env() {
    local arq=/etc/alertachuva/monitor.env linha chave valor
    [[ -r "$arq" ]] || return 0
    while IFS= read -r linha; do
        [[ "$linha" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        chave="${BASH_REMATCH[1]}"; valor="${BASH_REMATCH[2]}"
        valor="${valor#\"}"; valor="${valor%\"}"
        [[ -z "${!chave:-}" ]] && export "${chave}=${valor}"
    done < "$arq"
    return 0
}
carregar_env

LOG_DIR="${LOG_DIR:-/var/log/alertachuva}"
ESTADO_DIR="${ESTADO_DIR:-/var/lib/alertachuva}"
CPU_LIMITE="${CPU_LIMITE:-80}"
MEM_LIMITE="${MEM_LIMITE:-80}"
DISCO_LIMITE="${DISCO_LIMITE:-85}"
MONITOR_INTERVALO="${MONITOR_INTERVALO:-15}"
DISCO_PONTOS="${DISCO_PONTOS:-/}"
API_URL_SAUDE="${API_URL_SAUDE:-http://127.0.0.1:8000/api/saude}"

# shellcheck source=lib/comum.sh
source "$DIR/lib/comum.sh"
set -uo pipefail
trap 'log ERRO "erro na linha $LINENO (código $?): $BASH_COMMAND"' ERR

alerta() {
    log ALERTA "$*"
    _anexar "${LOG_DIR}/alertas.log" "$(_ts) | $(hostname) | ${SCRIPT_NOME} | ALERTA | $*"
}

validar_config() {
    local nome valor
    for nome in CPU_LIMITE MEM_LIMITE DISCO_LIMITE; do
        valor="${!nome}"
        if ! [[ "$valor" =~ ^[0-9]+$ ]] || (( valor < 1 || valor > 100 )); then
            log ERRO "configuração inválida: ${nome}='${valor}' (esperado inteiro de 1 a 100)"
            auditar "validar configuração do monitor" FALHA "${nome}=${valor}"
            exit 2
        fi
    done
    if ! [[ "$MONITOR_INTERVALO" =~ ^[0-9]+$ ]] || (( MONITOR_INTERVALO < 5 )); then
        log ERRO "configuração inválida: MONITOR_INTERVALO='${MONITOR_INTERVALO}' (mínimo 5 segundos)"
        exit 2
    fi
}

uso_cpu() {
    local a b
    read -r -a a < /proc/stat
    sleep 1
    read -r -a b < /proc/stat
    awk -v u1="${a[1]}" -v n1="${a[2]}" -v s1="${a[3]}" -v i1="${a[4]}" -v w1="${a[5]}" -v q1="${a[6]}" -v r1="${a[7]}" -v t1="${a[8]:-0}" \
        -v u2="${b[1]}" -v n2="${b[2]}" -v s2="${b[3]}" -v i2="${b[4]}" -v w2="${b[5]}" -v q2="${b[6]}" -v r2="${b[7]}" -v t2="${b[8]:-0}" \
        'BEGIN { tot=(u2+n2+s2+i2+w2+q2+r2+t2)-(u1+n1+s1+i1+w1+q1+r1+t1); ocioso=(i2+w2)-(i1+w1);
                 printf "%.1f", (tot>0 ? 100*(tot-ocioso)/tot : 0) }'
}

uso_memoria() {
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END { printf "%.1f", 100*(t-a)/t }' /proc/meminfo
}

uso_disco() { df -P "$1" 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print $5 }'; }

estado_api() {
    if curl --noproxy '*' -fsS --max-time 3 "$API_URL_SAUDE" >/dev/null 2>&1; then echo ok; else echo falha; fi
}

servico_api() { local e; e=$(systemctl is-active alertachuva.service 2>/dev/null); echo "${e:-desconhecido}"; }

acima() { awk -v v="$1" -v l="$2" 'BEGIN { exit !(v > l) }'; }

transicao() {
    local novo="$2" arq="${ESTADO_DIR}/estado_${1}" antigo="normal"
    [[ -r "$arq" ]] && antigo=$(<"$arq")
    [[ -w "$ESTADO_DIR" ]] && echo "$novo" > "$arq"
    [[ "$antigo" != "$novo" ]] && echo "$antigo"
    return 0
}

verificar() {
    local cpu mem api ponto d anterior chave disco_txt="" disco_csv="" alertas=0
    local -A disco=()
    cpu=$(uso_cpu)
    mem=$(uso_memoria)
    for ponto in $DISCO_PONTOS; do
        d=$(uso_disco "$ponto")
        if [[ -z "$d" ]]; then log ERRO "não foi possível ler o uso de disco de ${ponto}"; continue; fi
        disco[$ponto]=$d
        disco_txt+=" disco[${ponto}]=${d}%"
        disco_csv="${disco_csv:-$d}"
    done
    api=$(estado_api)

    log INFO "VERIFICAÇÃO cpu=${cpu}% mem=${mem}%${disco_txt} api=${api}"
    _anexar "${LOG_DIR}/metricas.csv" "$(_ts),${cpu},${mem},${disco_csv},${api}"

    if acima "$cpu" "$CPU_LIMITE"; then
        alerta "CPU em ${cpu}% (limite ${CPU_LIMITE}%)"; alertas=$((alertas + 1)); transicao cpu alto >/dev/null
    else
        anterior=$(transicao cpu normal); [[ "$anterior" == "alto" ]] && log OK "CPU normalizada em ${cpu}%"
    fi
    if acima "$mem" "$MEM_LIMITE"; then
        alerta "MEMÓRIA em ${mem}% (limite ${MEM_LIMITE}%)"; alertas=$((alertas + 1)); transicao mem alto >/dev/null
    else
        anterior=$(transicao mem normal); [[ "$anterior" == "alto" ]] && log OK "MEMÓRIA normalizada em ${mem}%"
    fi
    for ponto in "${!disco[@]}"; do
        d=${disco[$ponto]}; chave="disco${ponto//\//_}"
        if acima "$d" "$DISCO_LIMITE"; then
            alerta "DISCO ${ponto} em ${d}% (limite ${DISCO_LIMITE}%)"; alertas=$((alertas + 1)); transicao "$chave" alto >/dev/null
        else
            anterior=$(transicao "$chave" normal); [[ "$anterior" == "alto" ]] && log OK "DISCO ${ponto} normalizado em ${d}%"
        fi
    done
    if [[ "$api" == "falha" ]]; then
        log ERRO "API sem resposta em ${API_URL_SAUDE} (serviço alertachuva: $(servico_api))"
        _anexar "${LOG_DIR}/alertas.log" "$(_ts) | $(hostname) | ${SCRIPT_NOME} | ALERTA | API fora do ar"
        alertas=$((alertas + 1)); transicao api falha >/dev/null
    else
        anterior=$(transicao api ok); [[ "$anterior" == "falha" ]] && log OK "API voltou a responder"
    fi
    return $(( alertas > 0 ? 1 : 0 ))
}

parar() {
    log INFO "monitor parado pelo sinal $1 (pid $$)"
    auditar "parar monitor" OK "sinal=$1"
    exit 0
}

continuo() {
    trap 'parar TERM' TERM
    trap 'parar INT' INT
    log INFO "monitor iniciado (pid $$, intervalo ${MONITOR_INTERVALO}s, limites cpu=${CPU_LIMITE}% mem=${MEM_LIMITE}% disco=${DISCO_LIMITE}%)"
    auditar "iniciar monitor" OK "pid=$$"
    while true; do
        verificar || true
        sleep "$MONITOR_INTERVALO" &
        wait $!
    done
}

validar_config
case "${1:---uma-vez}" in
    --continuo) continuo ;;
    --uma-vez) verificar || exit 1 ;;
    *) echo "uso: $0 [--uma-vez|--continuo]" >&2; exit 2 ;;
esac
