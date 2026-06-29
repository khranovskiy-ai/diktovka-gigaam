#!/bin/bash
# ============================================================
#  Диктовка ГигаАМ - установщик (бесплатный подарок)
#  Ставит всё сам. Модель берётся из пакета (офлайн) или из кэша.
# ============================================================
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.gigaam-dictation"
CFGDIR="$HOME/.config/whisper-skill"
HFHUB="$HOME/.cache/huggingface/hub"
VPY="$DEST/.venv/bin/python"

clear
echo "============================================================"
echo "   Установка «Диктовка ГигаАМ»"
echo "   Идёт установка - это нормально. Ничего нажимать не надо,"
echo "   я сам напишу, когда понадобишься. НЕ закрывай это окно."
echo "============================================================"
echo

step(){ echo; echo ">>> $1"; }

# --- 1. исходники + конфиг ---
step "Шаг 1 из 5: копирую программу"
mkdir -p "$DEST" "$CFGDIR" "$HFHUB"
cp -R "$HERE/src/." "$DEST/"
cp "$HERE/config/voice_dictation.json" "$CFGDIR/voice_dictation.json"
echo "ок"

# --- 2. модель (офлайн из пакета, иначе кэш, иначе скачать) ---
step "Шаг 2 из 5: голосовой движок (модель)"
if [ -d "$HERE/model/models--istupakov--gigaam-v3-onnx" ]; then
  echo "беру модель из пакета (офлайн)..."
  cp -R "$HERE/model/"* "$HFHUB/"
  echo "ок (из пакета)"
elif [ -d "$HFHUB/models--istupakov--gigaam-v3-onnx" ]; then
  echo "ок (модель уже есть в кэше)"
else
  echo "модели в пакете нет - скачаю при первом запуске (нужен интернет один раз)."
fi

# --- 3. uv + Python 3.11 (закреплённая версия uv + проверка контрольной суммы) ---
step "Шаг 3 из 5: рабочее окружение Python (поставлю, если нет)"
export PATH="$HOME/.local/bin:$PATH"
UV_VER="0.11.25"
UV_SHA="ca2de1bca2913ba30ce88658b6d90a663c627ecac378803aa58084a9adb35a46"
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
  echo "ставлю uv $UV_VER (с проверкой контрольной суммы установщика)..."
  TMP_UV="$(mktemp)"
  curl -sL --max-time 60 "https://astral.sh/uv/${UV_VER}/install.sh" -o "$TMP_UV"
  GOT_SHA="$(shasum -a 256 "$TMP_UV" | awk '{print $1}')"
  if [ "$GOT_SHA" != "$UV_SHA" ]; then
    echo "❌ Контрольная сумма установщика uv НЕ совпала ($GOT_SHA)."
    echo "   Возможна подмена в сети. Установка прервана для безопасности."
    rm -f "$TMP_UV"; read -p "Enter чтобы закрыть..."; exit 1
  fi
  sh "$TMP_UV"; rm -f "$TMP_UV"
fi
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
"$UV" python install 3.11 >/dev/null 2>&1
"$UV" venv --python 3.11 "$DEST/.venv" >/dev/null 2>&1
echo "ок"

# --- 4. зависимости (зафиксированные версии + проверка хэшей каждого пакета) ---
step "Шаг 4 из 5: ставлю компоненты распознавания (это пара минут)"
"$UV" pip install --python "$VPY" -q --require-hashes -r "$HERE/requirements.lock" \
  || { echo "ОШИБКА: хэш пакета не совпал или нет интернета. Покажи это окно автору."; read -p "Enter..."; exit 1; }
echo "ок (версии и хэши проверены)"

# --- 5. кнопки на Рабочем столе (рабочие шаблоны из пакета) ---
step "Шаг 5 из 5: кнопки на Рабочем столе"
DESK="$HOME/Desktop"
# рабочие кнопки (гасят PuntoSwitcher на время диктовки, окно закрывается само)
cp "$HERE/launchers/Диктовка ГигаАМ - включить.command" "$DESK/"
cp "$HERE/launchers/Диктовка ГигаАМ - выключить.command" "$DESK/"
cp "$HERE/launchers/Диктовка ГигаАМ - проверить.command" "$DESK/" 2>/dev/null || true

cat > "$DESK/Диктовка ГигаАМ - удалить.command" <<'DEL'
#!/bin/bash
pkill -f "examples.voice_dictation" 2>/dev/null
rm -rf "$HOME/.gigaam-dictation"
rm -rf "$HOME/.config/whisper-skill"
rm -f "$HOME/Desktop/Диктовка ГигаАМ - включить.command" "$HOME/Desktop/Диктовка ГигаАМ - выключить.command" "$HOME/Desktop/Диктовка ГигаАМ - проверить.command"
echo "Диктовка удалена. (Разрешения «Терминала» можешь убрать в Системных настройках вручную.)"
echo "Эту кнопку «удалить» можно теперь тоже стереть в корзину."
sleep 2
DEL

chmod +x "$DESK/Диктовка ГигаАМ - включить.command" "$DESK/Диктовка ГигаАМ - выключить.command" "$DESK/Диктовка ГигаАМ - проверить.command" "$DESK/Диктовка ГигаАМ - удалить.command"
echo "ок"

# --- проверка движка: убедиться, что это ГигаАМ, а не Whisper ---
step "Проверяю, что распознаёт именно ГигаАМ..."
ENGINE_OK=$(HF_HUB_OFFLINE=1 "$VPY" - <<'PY' 2>/dev/null
try:
    import onnx_asr
    m = onnx_asr.load_model("gigaam-v3-e2e-rnnt", providers=["CPUExecutionProvider"])
    print("GIGAAM_OK")
except Exception as e:
    print("FAIL", e)
PY
)
echo "$ENGINE_OK" | grep -q GIGAAM_OK && echo "ок - движок ГигаАМ загружается" || echo "ВНИМАНИЕ: движок не загрузился, скажи автору"

# --- разрешения ---
step "Последнее: выдать Маку 3 разрешения (один раз)"
echo "Сейчас Мак спросит про микрофон/клавишу. Дальше я открою 2 окна настроек -"
echo "в каждом включи переключатель «Терминал» (увидишь в списке «Терминал» - это правильно)."
echo
"$VPY" scripts/request_permissions.py 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null

echo
echo "============================================================"
echo "  ГОТОВО. Что дальше:"
echo "   1) В двух открытых окнах включи «Терминал» (синий переключатель)."
echo "   2) Дважды щёлкни на Рабочем столе «Диктовка ГигаАМ - включить»."
echo "   3) В любом поле зажми Option, говори, отпусти - текст появится."
echo "  Не работает? Кнопка «Диктовка ГигаАМ - проверить»."
echo "============================================================"
read -p "Нажми Enter чтобы закрыть это окно..."
