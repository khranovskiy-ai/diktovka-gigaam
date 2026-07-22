#!/bin/bash
# Перегенерировать ОБА lock-файла (Mac И Windows) из requirements.in ОДНИМ прогоном
# и вписать в шапки sha256 requirements.in. Правило: зависимости меняются только
# этой кнопкой - иначе платформы тихо разъедутся по версиям движка (находка совета).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
cd "$HERE"
uv pip compile requirements.in --generate-hashes --python-version 3.11 -o requirements.lock
uv pip compile requirements.in --generate-hashes --python-version 3.11 \
  --python-platform x86_64-pc-windows-msvc -o requirements-windows.lock
sed -i '' "s|$HERE/requirements.in|requirements.in|" requirements.lock requirements-windows.lock
SHA="$(shasum -a 256 requirements.in | awk '{print $1}')"
for f in requirements.lock requirements-windows.lock; do
  grep -v '^# source-requirements-sha256:' "$f" > "$f.tmp"
  { head -1 "$f.tmp"; echo "# source-requirements-sha256: $SHA"; tail -n +2 "$f.tmp"; } > "$f"
  rm "$f.tmp"
done
echo "Готово: оба lock обновлены синхронно, sha=$SHA"
echo "Не забудь: пересобрать архив и проверить установку на Mac."
read -p "Enter чтобы закрыть"
