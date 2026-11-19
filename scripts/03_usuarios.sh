#!/usr/bin/env bash
# Etapa 3 · usuários, grupos, permissões e sudo restrito para a operação dos serviços.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
modo_estrito
exigir_root
preparar_log_dir

criar_grupos() {
    getent group "$GRUPO_OPS" >/dev/null || groupadd --system "$GRUPO_OPS"
    getent group "$APP_USUARIO" >/dev/null || groupadd --system "$APP_USUARIO"
    getent group "$GRUPO_OPS" "$APP_USUARIO"
}

criar_usuarios_servico() {
    id "$APP_USUARIO" >/dev/null 2>&1 || useradd --system --gid "$APP_USUARIO" --home-dir "$APP_DIR" \
        --no-create-home --shell /usr/sbin/nologin --comment "AlertaChuva API" "$APP_USUARIO"
    id "$MON_USUARIO" >/dev/null 2>&1 || useradd --system --gid "$GRUPO_OPS" --home-dir "$ESTADO_DIR" \
        --no-create-home --shell /usr/sbin/nologin --comment "AlertaChuva monitor" "$MON_USUARIO"
    id "$APP_USUARIO"
    id "$MON_USUARIO"
}

criar_operador() {
    id "$OPERADOR" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --comment "Operador AlertaChuva" "$OPERADOR"
    usermod -aG "$GRUPO_OPS" "$OPERADOR"
    passwd -l "$OPERADOR" >/dev/null
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        usermod -aG "$GRUPO_OPS" "$SUDO_USER"
        echo "${SUDO_USER} adicionado ao grupo ${GRUPO_OPS}"
    fi
    id "$OPERADOR"
}

configurar_sudo() {
    local arq=/etc/sudoers.d/alertachuva tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# AlertaChuva · o grupo de operação administra só os serviços do projeto
Cmnd_Alias ALERTACHUVA_SVC = /usr/bin/systemctl start alertachuva.service, /usr/bin/systemctl stop alertachuva.service, \\
    /usr/bin/systemctl restart alertachuva.service, /usr/bin/systemctl status alertachuva.service, \\
    /usr/bin/systemctl start alertachuva-monitor.service, /usr/bin/systemctl stop alertachuva-monitor.service, \\
    /usr/bin/systemctl restart alertachuva-monitor.service, /usr/bin/systemctl status alertachuva-monitor.service, \\
    /usr/bin/journalctl -u alertachuva.service *, /usr/bin/journalctl -u alertachuva-monitor.service *
%${GRUPO_OPS} ALL=(root) NOPASSWD: ALERTACHUVA_SVC
EOF
    visudo -cf "$tmp"
    install -m 0440 -o root -g root "$tmp" "$arq"
    rm -f "$tmp"
}

executar "criar grupos ${GRUPO_OPS} e ${APP_USUARIO}" criar_grupos
executar "criar usuários de serviço ${APP_USUARIO} e ${MON_USUARIO} (sem login)" criar_usuarios_servico
executar "criar usuário ${OPERADOR} e incluir operadores no grupo ${GRUPO_OPS}" criar_operador
executar "configurar sudo restrito para ${GRUPO_OPS}" configurar_sudo
