#!/usr/bin/env bash
# Biblioteca comum dos scripts AlertaChuva: logs, auditoria, tratamento de erros e utilidades.
# Formato de log: data/hora | host | script | nível | mensagem

LOG_DIR="${LOG_DIR:-/var/log/alertachuva}"
LOG_ARQUIVO="${LOG_ARQUIVO:-provisionamento.log}"
SCRIPT_NOME="${SCRIPT_NOME:-$(basename "${0}")}"

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

_anexar() {
    local arquivo="$1"; shift
    if [[ -e "$arquivo" && -w "$arquivo" ]] || [[ ! -e "$arquivo" && -d "$(dirname "$arquivo")" && -w "$(dirname "$arquivo")" ]]; then
        printf '%s\n' "$*" >> "$arquivo"
    fi
}

log() {
    local nivel="$1"; shift
    local linha cor fim=$'\e[0m'
    linha="$(_ts) | $(hostname) | ${SCRIPT_NOME} | ${nivel} | $*"
    case "$nivel" in
        OK) cor=$'\e[32m' ;; ALERTA) cor=$'\e[33m' ;; ERRO) cor=$'\e[31m' ;; *) cor=$'\e[36m' ;;
    esac
    if [[ -t 1 ]]; then printf '%s%s%s\n' "$cor" "$linha" "$fim"; else printf '%s\n' "$linha"; fi
    _anexar "${LOG_DIR}/${LOG_ARQUIVO}" "$linha"
    case "$nivel" in
        ERRO)   _anexar "${LOG_DIR}/erros.log" "$linha"; logger -t alertachuva -p user.err "${SCRIPT_NOME}: $*" 2>/dev/null || true ;;
        ALERTA) logger -t alertachuva -p user.warning "${SCRIPT_NOME}: $*" 2>/dev/null || true ;;
    esac
}

auditar() {
    local acao="$1" resultado="$2" detalhe="${3:-}"
    _anexar "${LOG_DIR}/auditoria.log" "$(_ts) | $(hostname) | usuario=${SUDO_USER:-$(id -un)} | ${SCRIPT_NOME} | ${acao} | ${resultado} | ${detalhe}"
}

executar() {
    local descricao="$1"; shift
    local inicio saida rc=0
    inicio=$(date +%s)
    log INFO "INÍCIO: ${descricao}"
    saida=$("$@" 2>&1) || rc=$?
    if [[ -n "$saida" ]]; then
        _anexar "${LOG_DIR}/${LOG_ARQUIVO}" "$(printf '%s\n' "$saida" | sed 's/^/        > /')"
    fi
    local dur=$(( $(date +%s) - inicio ))
    if (( rc == 0 )); then
        log OK "${descricao} (${dur}s)"
        auditar "$descricao" OK "${dur}s"
    else
        log ERRO "${descricao} falhou com código ${rc} (${dur}s): $(printf '%s' "$saida" | tail -n 3 | tr '\n' ' ')"
        auditar "$descricao" FALHA "codigo=${rc}"
    fi
    return "$rc"
}

_ao_falhar() {
    local rc=$? linha="$1" comando="$2"
    trap - ERR
    log ERRO "falha não tratada na linha ${linha} (código ${rc}): ${comando}"
    auditar "execução de ${SCRIPT_NOME}" FALHA "linha=${linha} codigo=${rc}"
    exit "$rc"
}

modo_estrito() {
    set -Eeuo pipefail
    trap '_ao_falhar "$LINENO" "$BASH_COMMAND"' ERR
}

exigir_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Este script precisa de root. Use: sudo bash $0" >&2
        exit 1
    fi
}

eh_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }

systemd_ativo() { [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; }

preparar_log_dir() {
    install -d -m 2751 "$LOG_DIR"
    touch "${LOG_DIR}/${LOG_ARQUIVO}" "${LOG_DIR}/auditoria.log" "${LOG_DIR}/erros.log"
}

carregar_infra() {
    local raiz="$1"
    # shellcheck source=../../config/infra.conf
    source "${raiz}/config/infra.conf"
}
