#!/usr/bin/env bash
# AlertaChuva · falha controlada: tenta carregar um arquivo de configuração que não existe.
# Serve para provar que erros de script são capturados e registrados em erros.log e auditoria.log.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
LOG_ARQUIVO="testes.log"
modo_estrito
exigir_root
preparar_log_dir

log INFO "simulando falha: leitura de ${CONF_DIR}/inexistente.conf"
cp "${CONF_DIR}/inexistente.conf" /tmp/alertachuva_teste.conf
log OK "esta linha não deve ser executada"
