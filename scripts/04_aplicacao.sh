#!/usr/bin/env bash
# Etapa 4 · diretórios, código da API, modelo de ML, ambiente Python, variáveis de ambiente e permissões.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
REPO="$(dirname "$RAIZ")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
modo_estrito
exigir_root
preparar_log_dir

CSV="dados_A701_D_2006-07-24_2025-04-25.csv"
MODELO_ORIGEM="$RAIZ/modelo"
DADOS_ORIGEM="$RAIZ/dados"
[[ -f "$MODELO_ORIGEM/xgb_alertachuva.json" ]] || MODELO_ORIGEM="$REPO/ml/modelo"
[[ -f "$DADOS_ORIGEM/$CSV" ]] || DADOS_ORIGEM="$REPO/ml/dados/raw"

verificar_origem() {
    for f in "$RAIZ/app/app.py" "$RAIZ/app/requirements.txt" "$MODELO_ORIGEM/xgb_alertachuva.json" \
             "$MODELO_ORIGEM/config.json" "$DADOS_ORIGEM/$CSV"; do
        [[ -f "$f" ]] || { echo "arquivo ausente: $f"; return 1; }
        echo "ok: $f"
    done
}

criar_diretorios() {
    install -d -m 0755 -o root -g root "$APP_DIR" "$APP_DIR/bin"
    install -d -m 0750 -o root -g "$APP_USUARIO" "$APP_DIR/app" "$APP_DIR/modelo" "$APP_DIR/dados"
    install -d -m 0755 -o root -g root "$CONF_DIR"
    install -d -m 2751 -o root -g "$GRUPO_OPS" "$LOG_DIR"
    install -d -m 2750 -o "$APP_USUARIO" -g "$GRUPO_OPS" "$LOG_DIR/app"
    install -d -m 0750 -o "$MON_USUARIO" -g "$GRUPO_OPS" "$ESTADO_DIR"
    for f in provisionamento.log auditoria.log erros.log monitor.log alertas.log metricas.csv; do
        touch "$LOG_DIR/$f"
        chown root:"$GRUPO_OPS" "$LOG_DIR/$f"
        chmod 0660 "$LOG_DIR/$f"
    done
    [[ -s "$LOG_DIR/metricas.csv" ]] || echo "data_hora,cpu_pct,mem_pct,disco_pct,api" > "$LOG_DIR/metricas.csv"
    ls -ld "$APP_DIR" "$APP_DIR"/* "$CONF_DIR" "$LOG_DIR" "$LOG_DIR"/* "$ESTADO_DIR"
}

copiar_aplicacao() {
    rm -rf "$APP_DIR/app/templates"
    install -m 0640 -o root -g "$APP_USUARIO" "$RAIZ/app/app.py" "$RAIZ/app/requirements.txt" "$APP_DIR/app/"
    install -d -m 0750 -o root -g "$APP_USUARIO" "$APP_DIR/app/templates"
    install -m 0640 -o root -g "$APP_USUARIO" "$RAIZ/app/templates/index.html" "$APP_DIR/app/templates/"
    install -m 0640 -o root -g "$APP_USUARIO" "$MODELO_ORIGEM/xgb_alertachuva.json" "$MODELO_ORIGEM/config.json" "$APP_DIR/modelo/"
    install -m 0640 -o root -g "$APP_USUARIO" "$DADOS_ORIGEM/$CSV" "$APP_DIR/dados/"
    install -m 0755 "$DIR/rede.sh" "$APP_DIR/bin/rede.sh"
    install -m 0750 -o root -g "$GRUPO_OPS" "$DIR/monitor.sh" "$APP_DIR/bin/monitor.sh"
    install -d -m 0755 "$APP_DIR/bin/lib"
    install -m 0644 "$DIR/lib/comum.sh" "$APP_DIR/bin/lib/comum.sh"
    sha256sum "$APP_DIR/modelo/xgb_alertachuva.json" "$APP_DIR/dados/$CSV" "$APP_DIR/app/app.py"
}

criar_venv() {
    [[ -x "$APP_DIR/venv/bin/python" ]] || python3 -m venv "$APP_DIR/venv"
    "$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
    "$APP_DIR/venv/bin/pip" install --quiet --no-cache-dir -r "$APP_DIR/app/requirements.txt"
    chown -R root:"$APP_USUARIO" "$APP_DIR/venv"
    chmod -R o-rwx "$APP_DIR/venv"
    "$APP_DIR/venv/bin/pip" freeze | grep -iE '^(flask|gunicorn|xgboost|pandas|numpy)'
}

gerar_variaveis() {
    cat > "$CONF_DIR/alertachuva.env" <<EOF
# AlertaChuva · variáveis de ambiente da API (gerado por 04_aplicacao.sh)
ALERTACHUVA_HOME=${APP_DIR}/app
ALERTACHUVA_MODELO_DIR=${APP_DIR}/modelo
ALERTACHUVA_DADOS_CSV=${APP_DIR}/dados/${CSV}
ALERTACHUVA_LOG_DIR=${LOG_DIR}/app
ALERTACHUVA_BAIRRO="${BAIRRO}"
ALERTACHUVA_PORTA=${APP_PORTA}
ALERTACHUVA_WORKERS=${APP_WORKERS}
PYTHONUNBUFFERED=1
EOF
    cat > "$CONF_DIR/monitor.env" <<EOF
# AlertaChuva · limites e intervalo do monitoramento (gerado por 04_aplicacao.sh)
LOG_DIR=${LOG_DIR}
ESTADO_DIR=${ESTADO_DIR}
CPU_LIMITE=${CPU_LIMITE}
MEM_LIMITE=${MEM_LIMITE}
DISCO_LIMITE=${DISCO_LIMITE}
MONITOR_INTERVALO=${MONITOR_INTERVALO}
DISCO_PONTOS="/ ${LOG_DIR}"
API_URL_SAUDE=http://127.0.0.1:${APP_PORTA}/api/saude
EOF
    chown root:"$APP_USUARIO" "$CONF_DIR/alertachuva.env"; chmod 0640 "$CONF_DIR/alertachuva.env"
    chown root:"$GRUPO_OPS" "$CONF_DIR/monitor.env"; chmod 0640 "$CONF_DIR/monitor.env"
    cat > /etc/profile.d/alertachuva.sh <<EOF
export ALERTACHUVA_LOGS=${LOG_DIR}
export ALERTACHUVA_URL=http://${DOMINIO}
alias ac-status='systemctl status alertachuva alertachuva-monitor alertachuva-rede nginx --no-pager'
alias ac-logs='tail -n 30 ${LOG_DIR}/monitor.log ${LOG_DIR}/alertas.log ${LOG_DIR}/erros.log'
EOF
    chmod 0644 /etc/profile.d/alertachuva.sh
    ls -l "$CONF_DIR" /etc/profile.d/alertachuva.sh
}

configurar_logrotate() {
    cat > /etc/logrotate.d/alertachuva <<EOF
${LOG_DIR}/*.log ${LOG_DIR}/*.csv {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0660 root ${GRUPO_OPS}
}
${LOG_DIR}/app/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    logrotate -d /etc/logrotate.d/alertachuva 2>&1 | tail -n 3
}

executar "verificar arquivos de origem (API, modelo e dados INMET)" verificar_origem
executar "criar diretórios e definir donos/permissões" criar_diretorios
executar "copiar API, modelo, dados e scripts para ${APP_DIR}" copiar_aplicacao
executar "criar ambiente Python e instalar dependências" criar_venv
executar "gerar variáveis de ambiente em ${CONF_DIR}" gerar_variaveis
executar "configurar rotação de logs (logrotate)" configurar_logrotate
