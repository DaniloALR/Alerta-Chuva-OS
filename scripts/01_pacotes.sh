#!/usr/bin/env bash
# Etapa 1 · instala os pacotes e dependências do sistema usados pela aplicação e pela administração.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
modo_estrito
exigir_root
preparar_log_dir

PACOTES=(
    python3 python3-venv python3-pip
    nginx
    curl jq ca-certificates
    dnsutils iproute2 iputils-ping
    procps stress-ng logrotate
)

export DEBIAN_FRONTEND=noninteractive

atualizar_indices() { apt-get update -q || { sleep 5; apt-get update -q; }; }

executar "atualizar índice de pacotes (apt update)" atualizar_indices
executar "instalar pacotes: ${PACOTES[*]}" apt-get install -y -q --no-install-recommends "${PACOTES[@]}"

for p in "${PACOTES[@]}"; do
    versao=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo "ausente")
    log INFO "pacote ${p} = ${versao}"
done
auditar "inventário de pacotes" OK "$(python3 --version 2>&1), $(nginx -v 2>&1 | tr -d '\n')"
