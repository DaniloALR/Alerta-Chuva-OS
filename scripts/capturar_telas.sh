#!/usr/bin/env bash
# AlertaChuva · tira as capturas de tela das evidências automaticamente (WSL).
# Mostra cada evidência no terminal e fotografa a janela ativa com o próprio Windows (PowerShell).
# Uso (como usuário normal, com o terminal MAXIMIZADO): bash scripts/capturar_telas.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$DIR")"
source "$DIR/lib/comum.sh"
carregar_infra "$RAIZ"
set -uo pipefail

CAPT="$RAIZ/evidencias/capturas"
mkdir -p "$CAPT"

PS=$(command -v powershell.exe || echo /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
if [[ ! -x "$PS" ]] || ! "$PS" -NoProfile -Command "exit 0" >/dev/null 2>&1; then
    echo "Não consegui chamar o PowerShell do Windows a partir do WSL (interop desligado)." >&2
    echo "Tire as capturas manualmente com Win + Shift + S." >&2
    exit 1
fi

WINTEMP=$(cd /mnt/c && cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')
TMPW=$(wslpath -u "$WINTEMP")
cat > "$TMPW/alertachuva_captura.ps1" <<'PS1'
param([string]$Saida)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Janela {
    [StructLayout(LayoutKind.Sequential)] public struct Ret { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Ret r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out Ret r, int s);
}
"@
[Janela]::SetProcessDPIAware() | Out-Null
$h = [Janela]::GetForegroundWindow()
$r = New-Object Janela+Ret
if ([Janela]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [Janela]::GetWindowRect($h, [ref]$r) | Out-Null }
$bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($Saida, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
PS1

fotografar() {
    local nome="$1"
    sleep 1
    "$PS" -NoProfile -ExecutionPolicy Bypass -File "$WINTEMP\\alertachuva_captura.ps1" -Saida "$WINTEMP\\$nome" >/dev/null 2>&1
    if [[ -s "$TMPW/$nome" ]]; then
        mv "$TMPW/$nome" "$CAPT/$nome"
        echo "$nome" >> "$TMPW/alertachuva_capturas_ok.txt"
    else
        echo "$nome" >> "$TMPW/alertachuva_capturas_falha.txt"
    fi
}

tela() {
    local titulo="$1"; shift
    clear
    printf '\e[1;36mAlertaChuva · %s\e[0m   \e[2m(%s · %s)\e[0m\n' "$titulo" "$(hostname)" "$(date '+%d/%m/%Y %H:%M:%S')"
    local cmd
    for cmd in "$@"; do
        printf '\n\e[1;32m%s@%s\e[0m:\e[1;34m~/%s\e[0m$ %s\n' "$(id -un)" "$(hostname)" "$(basename "$RAIZ")" "$cmd"
        bash -c "$cmd"
    done
}

rm -f "$TMPW"/alertachuva_capturas_*.txt
echo "Vou pedir a senha do sudo uma vez. Deixe esta janela MAXIMIZADA e em primeiro plano até o fim (cerca de 3 minutos)."
sudo -v || exit 1
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
MANTER_SUDO=$!
trap 'kill $MANTER_SUDO 2>/dev/null' EXIT
cd "$RAIZ" || exit 1
sleep 3

tela "Provisionamento" \
    "sudo grep -E 'ETAPA|etapa .* concluída|provisionamento (iniciado|concluído)' ${LOG_DIR}/provisionamento.log | tail -n 12 | cut -c1-170" \
    "sudo grep -c '| OK |' ${LOG_DIR}/provisionamento.log"
fotografar 01_provisionamento.png

tela "Validação da infraestrutura" "sudo bash scripts/validar.sh 2>&1 | cut -d'|' -f4- | cut -c1-150"
fotografar 02_validacao.png

tela "Serviços systemd" \
    "systemctl list-units 'alertachuva*' nginx.service --no-pager" \
    "systemctl list-unit-files 'alertachuva*' nginx.service --no-pager | head -n 6" \
    "systemctl show alertachuva-monitor -p User -p Restart -p RestartUSec -p NRestarts -p MainPID"
fotografar 04_servicos.png

clear
echo "Gerando consumo alto de CPU por 35 s para o monitor registrar o alerta..."
sudo stress-ng --cpu 0 --timeout 35s >/dev/null 2>&1 & STRESS=$!
sleep 34
tela "Monitoramento de CPU, memória e disco (durante stress-ng)" \
    "sudo tail -n 8 ${LOG_DIR}/monitor.log | cut -c1-170" \
    "sudo tail -n 4 ${LOG_DIR}/alertas.log | cut -c1-170" \
    "sudo tail -n 4 ${LOG_DIR}/metricas.csv"
fotografar 05_monitoramento.png
wait "$STRESS"

tela "Teste de falha · serviço de monitoramento" "sudo bash scripts/testes_falha.sh monitor 2>&1 | cut -c1-170"
fotografar 06_falha_monitor.png

tela "Teste de falha · API" "sudo bash scripts/testes_falha.sh api 2>&1 | grep -v '^evidência' | cut -c1-170"
fotografar 07_falha_api.png

tela "Teste de reinicialização" "sudo bash scripts/testes_falha.sh reinicio-depois 2>&1 | grep -v '^evidência' | cut -c1-170"
fotografar 08_reinicio.png

tela "Logs e auditoria" \
    "ls -l ${LOG_DIR}" \
    "sudo tail -n 8 ${LOG_DIR}/auditoria.log | cut -c1-170" \
    "sudo tail -n 5 ${LOG_DIR}/erros.log | cut -c1-170"
fotografar 09_logs.png

clear
echo "Abrindo a página do morador no navegador. Não clique em nada por 8 segundos..."
cmd.exe /c start "" "http://localhost/?data=2025-01-24" >/dev/null 2>&1
sleep 8
fotografar 03_aplicacao.png

echo
echo "==== Resultado ===="
[[ -f "$TMPW/alertachuva_capturas_ok.txt" ]] && echo "Capturas salvas em evidencias/capturas/: $(sort "$TMPW/alertachuva_capturas_ok.txt" | tr '\n' ' ')"
[[ -f "$TMPW/alertachuva_capturas_falha.txt" ]] && echo "Falharam: $(tr '\n' ' ' < "$TMPW/alertachuva_capturas_falha.txt")"
ls -l "$CAPT"/*.png 2>/dev/null
echo
echo "Confira as imagens no Explorer com:  cd $CAPT && explorer.exe ."
