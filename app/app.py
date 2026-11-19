import json
import logging
import os
import socket
import time
from datetime import date
from logging.handlers import RotatingFileHandler
from pathlib import Path

import numpy as np
import pandas as pd
import xgboost as xgb
from flask import Flask, jsonify, render_template, request

VERSAO = "1.0.0"
BASE = Path(os.environ.get("ALERTACHUVA_HOME", Path(__file__).resolve().parent))
MODELO_DIR = Path(os.environ.get("ALERTACHUVA_MODELO_DIR", BASE / "modelo"))
DADOS_CSV = Path(os.environ.get("ALERTACHUVA_DADOS_CSV", BASE / "dados" / "dados_A701_D_2006-07-24_2025-04-25.csv"))
LOG_DIR = Path(os.environ.get("ALERTACHUVA_LOG_DIR", BASE / "logs"))
BAIRRO = os.environ.get("ALERTACHUVA_BAIRRO", "Jardim Pantanal")

ACOES = {
    "BAIXO": "Sem alerta. Siga sua rotina e acompanhe o app.",
    "ATENÇÃO": "Fique atento: deixe documentos e remédios num lugar alto e o celular carregado.",
    "ALTO": "Risco alto de chuva muito forte amanhã: suba documentos, remédios e eletrônicos, combine com vizinhos a ajuda a quem tem mobilidade reduzida e acompanhe a Defesa Civil (199).",
}


def configurar_log():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = logging.getLogger("alertachuva")
    log.setLevel(logging.INFO)
    if not log.handlers:
        h = RotatingFileHandler(LOG_DIR / "app.log", maxBytes=2_000_000, backupCount=5, encoding="utf-8")
        h.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(message)s", "%Y-%m-%dT%H:%M:%S%z"))
        log.addHandler(h)
        log.addHandler(logging.StreamHandler())
    return log


def ler_bdmep(arquivo):
    df = pd.read_csv(arquivo, sep=";", skiprows=10, na_values="null")
    df = df.loc[:, ~df.columns.str.startswith("Unnamed")]
    df["data"] = pd.to_datetime(df.pop("Data Medicao"))
    df = df.set_index("data")
    df.columns = ["chuva", "temp", "umid", "vento"]
    return df.asfreq("D")


def montar_variaveis(df):
    X = pd.DataFrame(index=df.index)
    X["chuva_hoje"] = df.chuva
    for n in (3, 7, 15, 30):
        X[f"chuva_{n}d"] = df.chuva.rolling(n, min_periods=n - 1).sum()
    seco = df.chuva.lt(1).astype(int)
    X["dias_sem_chuva"] = seco.groupby((seco == 0).cumsum()).cumsum()
    X["temp"] = df.temp
    X["temp_var_1d"] = df.temp.diff()
    X["temp_anom_30d"] = df.temp - df.temp.rolling(30, min_periods=20).mean()
    X["umid"] = df.umid
    X["umid_var_1d"] = df.umid.diff()
    X["umid_3d"] = df.umid.rolling(3, min_periods=2).mean()
    X["vento"] = df.vento
    X["vento_var_1d"] = df.vento.diff()
    doy = df.index.dayofyear
    X["sazon_sin"] = np.sin(2 * np.pi * doy / 365.25)
    X["sazon_cos"] = np.cos(2 * np.pi * doy / 365.25)
    return X


log = configurar_log()
INICIO = time.time()
cfg = json.loads((MODELO_DIR / "config.json").read_text(encoding="utf-8"))
modelo = xgb.Booster()
modelo.load_model(str(MODELO_DIR / "xgb_alertachuva.json"))
modelo.set_param({"nthread": 1})
serie = ler_bdmep(DADOS_CSV)
X = montar_variaveis(serie)[cfg["features"]]
validas = X.dropna()
ULTIMA = validas.index.max().date()
PRIMEIRA = validas.index.min().date()
log.info("modelo carregado | %d dias válidos (%s a %s) | pid=%d", len(validas), PRIMEIRA, ULTIMA, os.getpid())

app = Flask(__name__)
app.json.ensure_ascii = False


def nivel(p):
    if p >= cfg["limiar_alto"]:
        return "ALTO"
    if p >= cfg["limiar_atencao"]:
        return "ATENÇÃO"
    return "BAIXO"


def prever(dia):
    ts = pd.Timestamp(dia)
    if ts not in validas.index:
        return None
    p = float(modelo.predict(xgb.DMatrix(validas.loc[[ts]]))[0])
    n = nivel(p)
    amanha = (ts + pd.Timedelta(days=1)).date()
    real = serie.chuva.get(pd.Timestamp(amanha))
    return {
        "bairro": BAIRRO,
        "data_base": str(ts.date()),
        "previsao_para": str(amanha),
        "indice_risco": round(p, 3),
        "nivel": n,
        "o_que_fazer": ACOES[n],
        "chuva_hoje_mm": None if pd.isna(serie.chuva.get(ts)) else float(serie.chuva.get(ts)),
        "chuva_observada_no_dia_seguinte_mm": None if real is None or pd.isna(real) else float(real),
    }


def data_pedida():
    texto = request.args.get("data")
    if not texto:
        return ULTIMA
    return date.fromisoformat(texto)


@app.after_request
def registrar(resp):
    log.info("%s %s %s %s", request.remote_addr, request.method, request.full_path.rstrip("?"), resp.status_code)
    return resp


@app.get("/api/saude")
def saude():
    return jsonify(status="ok", servico="alertachuva-api", versao=VERSAO, host=socket.gethostname(),
                   pid=os.getpid(), modelo=cfg["estacao"], dias_disponiveis=len(validas),
                   uptime_s=round(time.time() - INICIO, 1))


@app.get("/api/info")
def info():
    return jsonify(bairro=BAIRRO, alvo=cfg["alvo"], estacao=cfg["estacao"], treino_ate=cfg["treino_ate"],
                   limiares={"alto": cfg["limiar_alto"], "atencao": cfg["limiar_atencao"]},
                   periodo={"inicio": str(PRIMEIRA), "fim": str(ULTIMA)})


@app.get("/api/risco")
def risco():
    try:
        dia = data_pedida()
    except ValueError:
        log.warning("data inválida: %s", request.args.get("data"))
        return jsonify(erro="data inválida, use AAAA-MM-DD"), 400
    r = prever(dia)
    if r is None:
        return jsonify(erro=f"sem dados completos para {dia}", periodo={"inicio": str(PRIMEIRA), "fim": str(ULTIMA)}), 404
    return jsonify(r)


@app.get("/")
def pagina():
    try:
        dia = data_pedida()
    except ValueError:
        dia = ULTIMA
    r = prever(dia)
    return render_template("index.html", r=r, dia=dia, inicio=PRIMEIRA, fim=ULTIMA, host=socket.gethostname(), versao=VERSAO)


@app.errorhandler(Exception)
def erro_interno(e):
    if hasattr(e, "code"):
        return jsonify(erro=str(e)), e.code
    log.exception("erro interno")
    return jsonify(erro="erro interno"), 500
