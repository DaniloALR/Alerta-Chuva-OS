#!/usr/bin/env bash
# AlertaChuva · remove tudo o que o provisionamento criou, para reproduzir o ambiente do zero.
# Uso: sudo bash so/scripts/desinstalar.sh [--apagar-logs]
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
exigir_root
preparar_log_dir
set -uo pipefail

UNIDADES=(alertachuva-monitor.service alertachuva.service alertachuva-rede.service)

parar_servicos() {
    systemctl disable --now "${UNIDADES[@]}" 2>&1 || true
    rm -f "${UNIDADES[@]/#//etc/systemd/system/}"
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
}

remover_nginx() {
    rm -f /etc/nginx/sites-enabled/alertachuva /etc/nginx/sites-available/alertachuva
    [[ -e /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]] && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx 2>/dev/null || true
}

remover_arquivos() {
    rm -rf "$APP_DIR" "$CONF_DIR" "$ESTADO_DIR"
    rm -f /etc/sudoers.d/alertachuva /etc/profile.d/alertachuva.sh /etc/logrotate.d/alertachuva /etc/sysctl.d/90-alertachuva.conf
}

restaurar_rede() {
    [[ -f /etc/hostname.original ]] && mv /etc/hostname.original /etc/hostname && hostname "$(cat /etc/hostname)" 2>/dev/null
    [[ -f /etc/hosts.original ]] && cp -p /etc/hosts.original /etc/hosts && rm -f /etc/hosts.original
    if [[ -e /etc/resolv.conf.original || -L /etc/resolv.conf.original ]]; then
        rm -f /etc/resolv.conf && mv /etc/resolv.conf.original /etc/resolv.conf
    fi
    rm -f /etc/systemd/resolved.conf.d/alertachuva.conf
    [[ -f /etc/wsl.conf.original ]] && mv /etc/wsl.conf.original /etc/wsl.conf
    ip link del "$INTERFACE_SERVICO" 2>/dev/null || true
}

remover_usuarios() {
    for u in "$OPERADOR" "$MON_USUARIO" "$APP_USUARIO"; do id "$u" >/dev/null 2>&1 && userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true; done
    for g in "$APP_USUARIO" "$GRUPO_OPS"; do getent group "$g" >/dev/null && groupdel "$g" || true; done
}

executar "parar e remover serviços systemd" parar_servicos
executar "remover site Nginx" remover_nginx
executar "remover arquivos da aplicação e configurações" remover_arquivos
executar "restaurar hosts, DNS e wsl.conf originais" restaurar_rede
executar "remover usuários e grupos" remover_usuarios

if [[ "${1:-}" == "--apagar-logs" ]]; then
    rm -rf "$LOG_DIR"
    echo "logs apagados"
else
    log OK "desinstalação concluída; logs mantidos em ${LOG_DIR} para auditoria"
fi
