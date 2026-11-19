#!/usr/bin/env bash
# AlertaChuva · confere se a infraestrutura está como o provisionamento definiu.
# Uso: sudo bash so/scripts/validar.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
LOG_ARQUIVO="validacao.log"
exigir_root
preparar_log_dir
set -uo pipefail

total=0
falhas=0

checar() {
    local descricao="$1"; shift
    local saida rc=0
    total=$((total + 1))
    saida=$("$@" 2>&1) || rc=$?
    saida=$(printf '%s' "$saida" | tr '\n' ' ' | cut -c1-140)
    if (( rc == 0 )); then
        log OK "✔ ${descricao}${saida:+ · ${saida}}"
    else
        falhas=$((falhas + 1))
        log ERRO "✘ ${descricao}${saida:+ · ${saida}}"
    fi
}

hostname_ok() { local h; h=$(hostname); echo "$h"; [[ "$h" == "$HOSTNAME_ALVO" ]]; }
ip_ok() { ip -br addr | grep -F "${IP_SERVICO}/${PREFIXO_REDE}"; }
dns_local_ok() { local r; r=$(getent hosts "$DOMINIO" | awk '{print $1}'); echo "${DOMINIO} -> ${r}"; [[ "$r" == "$IP_SERVICO" ]]; }
dns_externo_ok() { getent hosts github.com | head -1; }
resolv_ok() { grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null || resolvectl dns 2>/dev/null; }
usuarios_ok() { id "$APP_USUARIO" && id "$MON_USUARIO" && id "$OPERADOR" | grep -q "$GRUPO_OPS"; }
login_bloqueado_ok() { local s; s=$(getent passwd "$APP_USUARIO" | cut -d: -f7); echo "shell=${s}"; [[ "$s" == */nologin ]]; }
sudo_ok() { visudo -cf /etc/sudoers.d/alertachuva; }
perm() { local alvo="$1" esperado="$2" r; r=$(stat -c '%a %U:%G' "$alvo"); echo "${alvo} ${r}"; [[ "$r" == "$esperado" ]]; }
venv_ok() { "$APP_DIR/venv/bin/python" -c 'from importlib.metadata import version as v; print(" | ".join(p + " " + v(p) for p in ("flask", "gunicorn", "xgboost-cpu", "pandas")))'; }
habilitado() { systemctl is-enabled "$1"; }
ativo() { systemctl is-active "$1"; }
api_saude_ok() { curl --noproxy '*' -fsS --max-time 5 "http://${DOMINIO}/api/saude" | jq -c '{status, host, pid}' | grep '"ok"'; }
api_risco_ok() { curl --noproxy '*' -fsS --max-time 5 "http://${IP_SERVICO}/api/risco?data=2025-01-24" | jq -c '{previsao_para, nivel, indice_risco}' | grep ALTO; }
pagina_ok() { curl --noproxy '*' -fsS --max-time 5 "http://localhost/" | grep -o '<title>[^<]*</title>'; }
monitor_recente_ok() {
    local ultima idade
    ultima=$(grep 'VERIFICAÇÃO' "$LOG_DIR/monitor.log" | tail -1)
    [[ -n "$ultima" ]] || { echo "nenhuma verificação registrada"; return 1; }
    idade=$(( $(date +%s) - $(date -d "$(cut -d'|' -f1 <<<"$ultima" | xargs)" +%s) ))
    echo "última há ${idade}s: $(cut -d'|' -f5 <<<"$ultima")"
    (( idade <= MONITOR_INTERVALO * 3 + 10 ))
}
logs_ok() { wc -l "$LOG_DIR"/auditoria.log "$LOG_DIR"/monitor.log "$LOG_DIR"/app/app.log | tail -1; [[ -s "$LOG_DIR/auditoria.log" ]]; }

log INFO "==== validação da infraestrutura ===="
checar "hostname definido como ${HOSTNAME_ALVO}" hostname_ok
checar "IP fixo ${IP_SERVICO}/${PREFIXO_REDE} ativo" ip_ok
checar "DNS local: ${DOMINIO} resolve para ${IP_SERVICO}" dns_local_ok
checar "DNS externo resolvendo nomes da internet" dns_externo_ok
checar "servidores DNS configurados" resolv_ok
checar "usuários ${APP_USUARIO}, ${MON_USUARIO} e ${OPERADOR} (grupo ${GRUPO_OPS})" usuarios_ok
checar "usuário de serviço ${APP_USUARIO} sem login interativo" login_bloqueado_ok
checar "sudo restrito do grupo ${GRUPO_OPS} válido" sudo_ok
checar "permissão do código da API" perm "$APP_DIR/app" "750 root:${APP_USUARIO}"
checar "permissão das variáveis de ambiente" perm "$CONF_DIR/alertachuva.env" "640 root:${APP_USUARIO}"
checar "permissão do diretório de logs" perm "$LOG_DIR" "2751 root:${GRUPO_OPS}"
checar "ambiente Python com as dependências" venv_ok
for u in alertachuva-rede.service alertachuva.service alertachuva-monitor.service nginx.service; do
    checar "${u} habilitado no boot" habilitado "$u"
    checar "${u} ativo" ativo "$u"
done
checar "API respondendo via Nginx em http://${DOMINIO}/api/saude" api_saude_ok
checar "previsão do modelo via http://${IP_SERVICO}/api/risco" api_risco_ok
checar "página do morador em http://localhost/" pagina_ok
checar "monitor registrando verificações periódicas" monitor_recente_ok
checar "logs de auditoria, monitor e API existentes" logs_ok

if (( falhas == 0 )); then
    log OK "validação: ${total}/${total} verificações OK"
    auditar "validar infraestrutura" OK "${total}/${total}"
else
    log ERRO "validação: $((total - falhas))/${total} OK, ${falhas} com falha"
    auditar "validar infraestrutura" FALHA "$((total - falhas))/${total}"
    exit 1
fi
