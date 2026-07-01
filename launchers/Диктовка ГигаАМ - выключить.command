#!/bin/bash
# ПОРЯДОК ВАЖЕН: сперва супервайзер (иначе тут же воскресит движок), потом сам движок.
pkill -f "examples.supervisor" 2>/dev/null; sleep 1
pkill -f "examples.voice_dictation" 2>/dev/null
rm -f "$HOME/.config/whisper-skill/supervisor.lock" "$HOME/.config/whisper-skill/voice_dictation.lock"
open -a PuntoSwitcher 2>/dev/null
echo "Диктовка выключена, PuntoSwitcher возвращён."
( sleep 1; osascript -e 'tell application "Terminal" to close front window' >/dev/null 2>&1 ) &
