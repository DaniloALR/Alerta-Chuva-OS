#!/usr/bin/env bash
# Etapa 5 · serviços systemd (API, monitor, rede), proxy Nginx e inicialização automática.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
modo_estrito
exigir_root
preparar_log_dir

UNIDADES=(alertachuva-rede.service alertachuva.service alertachuva-monitor.service)

instalar_unidades() {
    for u in "${UNIDADES[@]}"; do
        sed -e "s#@APP_DIR@#${APP_DIR}#g" -e "s#@CONF_DIR@#${CONF_DIR}#g" -e "s#@LOG_DIR@#${LOG_DIR}#g" \
            -e "s#@APP_USUARIO@#${APP_USUARIO}#g" -e "s#@MON_USUARIO@#${MON_USUARIO}#g" -e "s#@GRUPO_OPS@#${GRUPO_OPS}#g" -e "s#@ESTADO_DIR@#${ESTADO_DIR}#g" \
            "$RAIZ/config/systemd/$u" > "/etc/systemd/system/$u"
        chmod 0644 "/etc/systemd/system/$u"
    done
    systemd-analyze verify "${UNIDADES[@]/#//etc/systemd/system/}" 2>&1 | grep -v -E 'Unknown key|is not a directory' || true
    systemctl daemon-reload
}

configurar_nginx() {
    sed -e "s#@DOMINIO@#${DOMINIO}#g" -e "s#@IP_SERVICO@#${IP_SERVICO}#g" -e "s#@APP_PORTA@#${APP_PORTA}#g" \
        "$RAIZ/config/nginx/alertachuva.conf" > /etc/nginx/sites-available/alertachuva
    ln -sf /etc/nginx/sites-available/alertachuva /etc/nginx/sites-enabled/alertachuva
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
}

ativar_servicos() {
    systemctl enable alertachuva-rede.service alertachuva.service alertachuva-monitor.service nginx.service
    systemctl restart alertachuva-rede.service
    systemctl restart alertachuva.service
    systemctl restart nginx.service
    systemctl restart alertachuva-monitor.service
    systemctl is-enabled "${UNIDADES[@]}" nginx.service
}

aguardar_api() {

    for _ in $(seq 1 40); do
        if curl --noproxy '*' -fsS --max-time 3 "http://${DOMINIO}/api/saude"; then echo; return 0; fi
        sleep 2
    done
    systemctl status alertachuva.service --no-pager || true
    return 1
}

if ! systemd_ativo; then
    log ERRO "systemd não está ativo neste ambiente. No WSL: rode 'wsl --shutdown' no PowerShell, abra o Ubuntu e execute de novo."
    exit 3
fi

executar "instalar unidades systemd: ${UNIDADES[*]}" instalar_unidades
executar "configurar Nginx como proxy reverso para ${DOMINIO}" configurar_nginx
executar "habilitar inicialização automática e iniciar serviços" ativar_servicos
executar "aguardar a API responder em http://${DOMINIO}/api/saude" aguardar_api
