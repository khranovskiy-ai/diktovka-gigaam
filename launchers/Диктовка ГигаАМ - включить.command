#!/bin/bash
DEST="$HOME/.gigaam-dictation"; VPY="$DEST/.venv/bin/python"
export HF_HUB_OFFLINE=1
# Гасим Punto на время диктовки (в VS Code/Electron Punto глушит синтетическую вставку).
osascript -e 'tell application "PuntoSwitcher" to quit' 2>/dev/null
pkill -f "[P]untoSwitcher.app" 2>/dev/null
# ПОРЯДОК ВАЖЕН: сперва супервайзер (иначе он воскресит движок, который убьём следом), потом движок.
pkill -f "examples.supervisor" 2>/dev/null; sleep 1
pkill -f "examples.voice_dictation" 2>/dev/null; sleep 1
rm -f "$HOME/.config/whisper-skill/voice_dictation.lock" "$HOME/.config/whisper-skill/supervisor.lock"
cd "$DEST" || exit 1
"$VPY" scripts/request_permissions.py > "$HOME/.config/whisper-skill/perm_status.log" 2>&1
# Запускаем СУПЕРВАЙЗЕР в ОТДЕЛЬНОЙ СЕССИИ (os.setsid): окно можно закрыть - он переживёт,
# и Терминал НЕ спросит "прервать процессы?". exec в тот же python сохраняет разрешение
# Input Monitoring (TCC Терминала = «слух» Option). Супервайзер порождает движок дочерним
# процессом (тот наследует «слух») и АВТОМАТИЧЕСКИ перезапускает его при зависании/падении.
nohup "$VPY" -c "import os,sys
try: os.setsid()
except OSError: pass
os.execvp(sys.executable,[sys.executable,'-m','examples.supervisor'])" >/dev/null 2>&1 &
disown
clear
echo "Диктовка запущена и под присмотром супервайзера."
echo "Теперь она сама перезапустится, если что-то зависнет - кнопку жать не нужно."
echo "Окно закроется само..."
echo "(если Мак спросит «Терминал хочет управлять Терминалом» - нажми OK)"
( sleep 1; osascript -e 'tell application "Terminal" to close (every window whose name contains "включить")' >/dev/null 2>&1 ) &
disown
exit 0
