#!/bin/bash
DEST="$HOME/.gigaam-dictation"; VPY="$DEST/.venv/bin/python"
cd "$DEST" 2>/dev/null
clear; echo "Проверяю готовность..."; echo
"$VPY" scripts/request_permissions.py 2>/dev/null
if [ -d "/Applications/PuntoSwitcher.app" ]; then
  SC="$(defaults read ru.yandex.punto shortcutCancelLayoutChange 2>/dev/null)"
  if [ -z "$SC" ] || { echo "$SC" | grep -q "isAltUsed = 1" && echo "$SC" | grep -q "charKeycode = 666"; }; then
    echo "Punto Switcher: мешает (отпускание Option переворачивает раскладку) - нажмите «включить», она уберёт помеху."
  else
    echo "Punto Switcher: не мешает."
  fi
fi
echo; echo "Если выше «нет» - включите «Терминал» в открывшихся окнах."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null; sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null
read -p "Enter чтобы закрыть..."
