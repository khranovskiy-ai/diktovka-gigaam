#!/bin/bash
DEST="$HOME/.gigaam-dictation"; VPY="$DEST/.venv/bin/python"
export HF_HUB_OFFLINE=1
osascript -e 'tell application "PuntoSwitcher" to quit' 2>/dev/null
pkill -f "[P]untoSwitcher.app" 2>/dev/null
pkill -f "examples.voice_dictation" 2>/dev/null; sleep 1
rm -f "$HOME/.config/whisper-skill/voice_dictation.lock"
cd "$DEST" || exit 1
"$VPY" scripts/request_permissions.py > "$HOME/.config/whisper-skill/perm_status.log" 2>&1
# Движок запускаем в ОТДЕЛЬНОЙ СЕССИИ (os.setsid): окно можно закрыть - движок переживёт,
# и Терминал НЕ спросит "прервать процессы?". exec в тот же python сохраняет разрешения (TCC Терминала).
nohup "$VPY" -c "import os,sys
try: os.setsid()
except OSError: pass
os.execvp(sys.executable,[sys.executable,'-m','examples.voice_dictation'])" >/dev/null 2>&1 &
disown
clear
echo "Диктовка запущена. Окно закроется само..."
echo "(если Мак спросит «Терминал хочет управлять Терминалом» - нажми OK)"
# Закрываем ЭТО окно ОТЛОЖЕННО, уже ПОСЛЕ выхода из скрипта - тогда вопроса о процессах нет
# (движок в своей сессии, шелл окна завершён). Закрываем строго окно запуска (по имени).
( sleep 1; osascript -e 'tell application "Terminal" to close (every window whose name contains "включить")' >/dev/null 2>&1 ) &
disown
exit 0
