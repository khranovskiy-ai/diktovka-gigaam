#!/bin/bash
pkill -f "examples.voice_dictation" 2>/dev/null
open -a PuntoSwitcher 2>/dev/null
echo "Диктовка выключена, PuntoSwitcher возвращён."
( sleep 1; osascript -e 'tell application "Terminal" to close front window' >/dev/null 2>&1 ) &
