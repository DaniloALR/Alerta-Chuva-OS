# Modelo usado pela API

| Arquivo | Conteúdo |
|---|---|
| `xgb_alertachuva.json` | Modelo XGBoost treinado no notebook da disciplina de IA & Machine Learning (alvo: chuva ≥ 20 mm no dia seguinte) |
| `config.json` | Lista de variáveis, limiares dos níveis ATENÇÃO e ALTO e período de treino |

O `04_aplicacao.sh` copia estes arquivos para `/opt/alertachuva/modelo`, onde só o usuário de serviço `alertachuva` consegue ler.
