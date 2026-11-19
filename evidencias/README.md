# Evidências técnicas · Operating System

Evidências geradas no ambiente da equipe (WSL 2 com Ubuntu) pelos próprios scripts:

| Arquivo | Gerado por | Conteúdo |
|---|---|---|
| `01_sistema_e_rede.txt` | `coletar_evidencias.sh` | Sistema, hostname, IP fixo, rotas, `/etc/hosts`, DNS, `wsl.conf`, sysctl e resolução de nomes |
| `02_usuarios_e_permissoes.txt` | `coletar_evidencias.sh` | Usuários, grupos, sudo restrito e permissões de diretórios e arquivos |
| `03_servicos_systemd.txt` | `coletar_evidencias.sh` | Unidades habilitadas, status, política de reinício e arquivos `.service` |
| `04_aplicacao.txt` | `coletar_evidencias.sh` | Respostas da API via Nginx, cabeçalhos e portas em escuta |
| `05_monitoramento.txt` | `coletar_evidencias.sh` | Verificação do monitor, `monitor.log`, `alertas.log` e `metricas.csv` |
| `06_logs_e_auditoria.txt` | `coletar_evidencias.sh` | Auditoria, provisionamento, erros, log da API, Nginx e journal |
| `07_validacao.txt` | `coletar_evidencias.sh` | Resultado das 25 verificações do `validar.sh` |
| `testes/*.txt` | `testes_falha.sh` | Saída de cada teste de falha e recuperação |

## Capturas de tela (pasta `capturas/`)

Geradas por `bash so/scripts/capturar_telas.sh`, no WSL e com o terminal maximizado. O script mostra cada evidência no terminal e fotografa a janela com o próprio Windows (PowerShell), sem edição.

| Arquivo | Tela |
|---|---|
| `01_provisionamento.png` | Etapas 01 a 05 do `provisionar.sh` concluídas, lidas do `provisionamento.log` |
| `02_validacao.png` | `validar.sh` com todas as verificações OK |
| `03_aplicacao.png` | Página do morador em `http://localhost` no navegador (24/01/2025 → risco ALTO) |
| `04_servicos.png` | Serviços ativos, habilitados no boot e política de reinício do monitor |
| `05_monitoramento.png` | `monitor.log`, `alertas.log` e `metricas.csv` durante o `stress-ng` de CPU |
| `06_falha_monitor.png` | Teste `monitor`: PID antes e depois do `kill -9` |
| `07_falha_api.png` | Teste `api`: API derrubada, detectada pelo monitor e recuperada |
| `08_reinicio.png` | Teste `reinicio-depois`: boot novo com todos os serviços ativos |
| `09_logs.png` | `auditoria.log` e `erros.log` |
