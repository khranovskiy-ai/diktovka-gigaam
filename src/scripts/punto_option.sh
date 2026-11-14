#!/bin/bash
# Punto Switcher и диктовка - мирно, без выключения Punto (14.11.2026).
#
# Причина конфликта: у Punto «Отменить смену раскладки» по умолчанию висит на ОДИНОЧНОМ Option.
# Диктовка тоже на Option: человек отпускает Option - Punto принимает это за свою команду и
# переворачивает только что вставленную фразу («Диктую фразу?» -> «Lbrne. ahfpe&»).
# Лечение: снять у Punto ТОЛЬКО это одиночное нажатие Option. Автопереключение раскладки и
# остальные клавиши Punto не трогаем. Копия прежних настроек - в ~/.config/whisper-skill.
#
# Скрипт безопасно звать сколько угодно раз: если Option уже снят или Punto нет - ничего не делает.
# В конце Punto включён, если он установлен (прежние версии кнопок его гасили).

PUNTO_APP="/Applications/PuntoSwitcher.app"
DOMAIN="ru.yandex.punto"
CFGDIR="$HOME/.config/whisper-skill"

[ -d "$PUNTO_APP" ] || exit 0

SC="$(defaults read "$DOMAIN" shortcutCancelLayoutChange 2>/dev/null)"
NUZHNO=0
if [ -z "$SC" ]; then
  NUZHNO=1   # настройки нет - у Punto действует заводская (одиночный Option)
elif echo "$SC" | grep -q "isAltUsed = 1" \
     && echo "$SC" | grep -q "charKeycode = 666" \
     && ! echo "$SC" | grep -q -E "is(Command|Control|Shift)Used = 1"; then
  NUZHNO=1   # ровно одиночный Option
fi

if [ "$NUZHNO" = 1 ]; then
  mkdir -p "$CFGDIR"
  PLIST="$HOME/Library/Preferences/$DOMAIN.plist"
  [ -f "$PLIST" ] && cp -n "$PLIST" "$CFGDIR/punto.plist.do-diktovki" 2>/dev/null
  # Punto держит настройки в памяти и пишет их при выходе - меняем, пока он не запущен.
  pkill -x PuntoSwitcher 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x PuntoSwitcher >/dev/null || break; sleep 0.5; done
  defaults write "$DOMAIN" shortcutCancelLayoutChange -dict \
    charKeycode -int 666 isAltUsed -int 0 isCommandUsed -int 0 isControlUsed -int 0 isShiftUsed -int 0
  echo "Punto: снято одиночное нажатие Option («Отменить смену раскладки»), остальное как было."
fi

pgrep -x PuntoSwitcher >/dev/null || open -ga PuntoSwitcher 2>/dev/null
exit 0
