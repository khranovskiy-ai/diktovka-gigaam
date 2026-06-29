#!/bin/bash
DEST="$HOME/.gigaam-dictation"; VPY="$DEST/.venv/bin/python"
cd "$DEST" 2>/dev/null
clear; echo "Проверяю готовность..."; echo
"$VPY" scripts/request_permissions.py 2>/dev/null
echo; echo "Если выше «нет» - включи «Терминал» в открывшихся окнах."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null; sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null
read -p "Enter чтобы закрыть..."
