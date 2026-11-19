#!/usr/bin/env bash
# AlertaChuva · provisionamento completo e reproduzível do servidor Linux.
# Uso: sudo bash scripts/provisionar.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
modo_estrito
exigir_root
preparar_log_dir

ETAPAS=(01_pacotes 02_rede 03_usuarios 04_aplicacao 05_servicos)
inicio=$(date +%s)

rodar_etapa() {
    local etapa="$1" t0 rc=0
    t0=$(date +%s)
    log INFO "======== ETAPA ${etapa} ========"
    bash "$DIR/${etapa}.sh" || rc=$?
    if (( rc == 0 )); then
        log OK "etapa ${etapa} concluída ($(( $(date +%s) - t0 ))s)"
        auditar "etapa ${etapa}" OK "$(( $(date +%s) - t0 ))s"
    else
        log ERRO "etapa ${etapa} falhou (código ${rc}); veja ${LOG_DIR}/provisionamento.log"
        auditar "etapa ${etapa}" FALHA "codigo=${rc}"
        exit "$rc"
    fi
}

. /etc/os-release
log INFO "provisionamento iniciado | host=$(hostname) | ${PRETTY_NAME} | kernel=$(uname -r) | WSL=$(eh_wsl && echo sim || echo não) | systemd=$(systemd_ativo && echo ativo || echo inativo)"
auditar "iniciar provisionamento" OK "usuario=${SUDO_USER:-root}"

if ! systemd_ativo; then
    if eh_wsl; then
        rodar_etapa 01_pacotes
        rodar_etapa 02_rede
        log ALERTA "systemd foi habilitado no /etc/wsl.conf, mas só passa a valer depois de reiniciar o WSL."
        log ALERTA "No PowerShell do Windows rode: wsl --shutdown   · depois abra o Ubuntu e execute de novo: sudo bash scripts/provisionar.sh"
        exit 0
    fi
    log ERRO "este servidor não usa systemd; a solução exige systemd para os serviços."
    exit 1
fi

for etapa in "${ETAPAS[@]}"; do
    rodar_etapa "$etapa"
done

log OK "provisionamento concluído em $(( $(date +%s) - inicio ))s"
auditar "concluir provisionamento" OK "$(( $(date +%s) - inicio ))s"

bash "$DIR/validar.sh" || true

if [[ "$(hostname)" != "$HOSTNAME_ALVO" ]]; then
    log ALERTA "o hostname ${HOSTNAME_ALVO} fica definitivo depois de reiniciar: no WSL use 'wsl --shutdown' no PowerShell; em VM use 'sudo reboot'."
fi
