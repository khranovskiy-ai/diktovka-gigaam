#!/bin/bash
# ПОРЯДОК ВАЖЕН: сперва супервайзер (иначе тут же воскресит движок), потом сам движок.
pkill -f "examples.supervisor" 2>/dev/null; sleep 1
pkill -f "examples.voice_dictation" 2>/dev/null
rm -f "$HOME/.config/whisper-skill/supervisor.lock" "$HOME/.config/whisper-skill/voice_dictation.lock"
# Прежние версии гасили Punto Switcher - если он стоит и выключен, возвращаем.
if [ -d "/Applications/PuntoSwitcher.app" ] && ! pgrep -x PuntoSwitcher >/dev/null; then
  open -ga PuntoSwitcher 2>/dev/null
fi
echo "Диктовка выключена."
# Закрываем только своё окно, не чужое.
( sleep 1; osascript -e 'tell application "Terminal" to close (every window whose name contains "Диктовка ГигаАМ - выключить")' >/dev/null 2>&1 ) &
