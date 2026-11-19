#!/usr/bin/env bash
# Sobe ou remove o IP fixo do serviço AlertaChuva. Usado pela unidade alertachuva-rede.service.
set -euo pipefail

IFACE="${INTERFACE_SERVICO:-citizen0}"
IP="${IP_SERVICO:-10.20.30.10}"
PREFIXO="${PREFIXO_REDE:-24}"

subir() {
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        modprobe dummy 2>/dev/null || true
        if ! ip link add "$IFACE" type dummy 2>/dev/null; then
            echo "interface dummy indisponível; usando alias em lo"
            IFACE="lo"
        fi
    fi
    ip addr show dev "$IFACE" | grep -q " ${IP}/" || ip addr add "${IP}/${PREFIXO}" dev "$IFACE" label "${IFACE}" 2>/dev/null \
        || ip addr add "${IP}/${PREFIXO}" dev "$IFACE"
    ip link set "$IFACE" up
    echo "IP ${IP}/${PREFIXO} ativo em ${IFACE}"
}

descer() {
    if ip link show "$IFACE" >/dev/null 2>&1 && [[ "$IFACE" != "lo" ]]; then
        ip link del "$IFACE"
    else
        ip addr del "${IP}/${PREFIXO}" dev lo 2>/dev/null || true
    fi
    echo "IP ${IP} removido"
}

case "${1:-}" in
    subir) subir ;;
    descer) descer ;;
    *) echo "uso: $0 subir|descer" >&2; exit 2 ;;
esac
