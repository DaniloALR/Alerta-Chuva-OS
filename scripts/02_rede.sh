#!/usr/bin/env bash
# Etapa 2 · hostname, IP fixo do serviço, parâmetros de rede, DNS e resolução de nomes.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
modo_estrito
exigir_root
preparar_log_dir

FQDN="${HOSTNAME_ALVO}.${DOMINIO}"

ajustar_ini() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import configparser, sys
arq, secao, chave, valor = sys.argv[1:]
c = configparser.ConfigParser()
c.optionxform = str
c.read(arq)
if not c.has_section(secao):
    c.add_section(secao)
c.set(secao, chave, valor)
with open(arq, "w") as f:
    c.write(f, space_around_delimiters=False)
PY
}

configurar_wsl() {
    [[ -f /etc/wsl.conf && ! -f /etc/wsl.conf.original ]] && cp -p /etc/wsl.conf /etc/wsl.conf.original
    touch /etc/wsl.conf
    ajustar_ini /etc/wsl.conf boot systemd true
    ajustar_ini /etc/wsl.conf network hostname "$HOSTNAME_ALVO"
    ajustar_ini /etc/wsl.conf network generateHosts false
    ajustar_ini /etc/wsl.conf network generateResolvConf false
    cat /etc/wsl.conf
}

definir_hostname() {
    [[ -f /etc/hostname && ! -f /etc/hostname.original ]] && cp -p /etc/hostname /etc/hostname.original
    echo "$HOSTNAME_ALVO" > /etc/hostname
    if systemd_ativo; then hostnamectl set-hostname "$HOSTNAME_ALVO"; else hostname "$HOSTNAME_ALVO"; fi
    hostname
}

configurar_hosts() {
    [[ -f /etc/hosts.original ]] || cp -p /etc/hosts /etc/hosts.original
    local tmp
    tmp=$(mktemp)
    sed '/# >>> alertachuva/,/# <<< alertachuva/d' /etc/hosts | grep -vE "^127\.0\.1\.1[[:space:]]" > "$tmp"
    grep -qE '^127\.0\.0\.1[[:space:]]+localhost' "$tmp" || sed -i '1i 127.0.0.1\tlocalhost' "$tmp"
    cat >> "$tmp" <<EOF
# >>> alertachuva (gerenciado por 02_rede.sh)
127.0.1.1	${FQDN} ${HOSTNAME_ALVO}
${IP_SERVICO}	${DOMINIO} api.${DOMINIO} servico.${DOMINIO}
# <<< alertachuva
EOF
    cat "$tmp" > /etc/hosts
    rm -f "$tmp"
    cat /etc/hosts
}

instalar_unidade_rede() {
    install -d -m 0755 "$APP_DIR/bin" "$CONF_DIR"
    install -m 0755 "$DIR/rede.sh" "$APP_DIR/bin/rede.sh"
    cat > "$CONF_DIR/rede.env" <<EOF
INTERFACE_SERVICO=${INTERFACE_SERVICO}
IP_SERVICO=${IP_SERVICO}
PREFIXO_REDE=${PREFIXO_REDE}
EOF
    chmod 0644 "$CONF_DIR/rede.env"
    sed -e "s#@APP_DIR@#${APP_DIR}#g" -e "s#@CONF_DIR@#${CONF_DIR}#g" \
        "$RAIZ/config/systemd/alertachuva-rede.service" > /etc/systemd/system/alertachuva-rede.service
    if systemd_ativo; then
        systemctl daemon-reload
        systemctl enable alertachuva-rede.service
        systemctl restart alertachuva-rede.service
    else
        INTERFACE_SERVICO=$INTERFACE_SERVICO IP_SERVICO=$IP_SERVICO PREFIXO_REDE=$PREFIXO_REDE "$APP_DIR/bin/rede.sh" subir
    fi
    ip -br addr
}

aplicar_parametros_rede() {
    cat > /etc/sysctl.d/90-alertachuva.conf <<'EOF'
# AlertaChuva · parâmetros de rede do servidor web
net.core.somaxconn = 1024
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
    sysctl -e -p /etc/sysctl.d/90-alertachuva.conf
}

configurar_dns() {
    local atuais=() ns
    if [[ -f /etc/resolv.conf ]]; then
        while read -r _ ns; do atuais+=("$ns"); done < <(grep -E '^nameserver[[:space:]]' /etc/resolv.conf | grep -v '127.0.0.53' || true)
    fi
    if systemctl is-active --quiet systemd-resolved 2>/dev/null && ! eh_wsl; then
        install -d /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/alertachuva.conf <<EOF
[Resolve]
DNS=${DNS_SERVIDORES}
FallbackDNS=9.9.9.9
Domains=${DOMINIO}
EOF
        systemctl restart systemd-resolved
        resolvectl status | head -20
    else
        [[ -e /etc/resolv.conf.original || ! -e /etc/resolv.conf ]] || cp -P /etc/resolv.conf /etc/resolv.conf.original
        rm -f /etc/resolv.conf
        {
            echo "# AlertaChuva · gerado por 02_rede.sh"
            echo "search ${DOMINIO}"
            for ns in "${atuais[@]}" ${DNS_SERVIDORES}; do echo "nameserver ${ns}"; done | awk '!visto[$0]++' | head -3
            echo "options timeout:2 attempts:2"
        } > /etc/resolv.conf
        chmod 0644 /etc/resolv.conf
        cat /etc/resolv.conf
    fi
}

testar_resolucao() {
    getent hosts "$DOMINIO"
    getent hosts "api.${DOMINIO}"
    getent hosts "$HOSTNAME_ALVO"
    getent hosts portal.inmet.gov.br || getent hosts github.com
}

if eh_wsl; then
    executar "configurar /etc/wsl.conf (systemd, hostname, hosts e DNS fixos)" configurar_wsl
fi
executar "definir hostname ${HOSTNAME_ALVO}" definir_hostname
executar "configurar /etc/hosts (${DOMINIO} -> ${IP_SERVICO})" configurar_hosts
executar "configurar IP fixo ${IP_SERVICO}/${PREFIXO_REDE} na interface ${INTERFACE_SERVICO}" instalar_unidade_rede
executar "aplicar parâmetros de rede (sysctl)" aplicar_parametros_rede
executar "configurar DNS (${DNS_SERVIDORES})" configurar_dns
executar "testar resolução de nomes" testar_resolucao
