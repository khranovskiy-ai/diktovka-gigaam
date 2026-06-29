#!/bin/bash
DEST="$HOME/.gigaam-dictation"; VPY="$DEST/.venv/bin/python"
export HF_HUB_OFFLINE=1
osascript -e 'tell application "PuntoSwitcher" to quit' 2>/dev/null
pkill -f "[P]untoSwitcher.app" 2>/dev/null
pkill -f "examples.voice_dictation" 2>/dev/null; sleep 1
rm -f "$HOME/.config/whisper-skill/voice_dictation.lock"
cd "$DEST" || exit 1
"$VPY" scripts/request_permissions.py > "$HOME/.config/whisper-skill/perm_status.log" 2>&1
nohup "$VPY" -m examples.voice_dictation >/dev/null 2>&1 &
disown
clear
echo "Диктовка запущена. Окно закроется само..."
echo "(если Мак спросит «Терминал хочет управлять Терминалом» - нажми OK)"
# закрыть это окно, чтобы оно не перехватывало авто-вставку
osascript -e 'tell application "Terminal" to close front window' >/dev/null 2>&1
