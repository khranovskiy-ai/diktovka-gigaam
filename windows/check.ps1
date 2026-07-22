# Кнопка «Диктовка ГигаАМ - проверить» (Windows) - диагностика по-человечески.
$ErrorActionPreference = "SilentlyContinue"
. "$PSScriptRoot\common.ps1"

$VPY = Join-Path $DEST ".venv\Scripts\python.exe"

Clear-Host
Write-Host "=== Проверка «Диктовки ГигаАМ» ==="
$ver = ""
$verFile = Join-Path $DEST "VERSION"
if (Test-Path $verFile) { $ver = (Get-Content $verFile -First 1) }
Write-Host ("Версия: " + $ver)
Write-Host ("Клавиша диктовки: " + (Get-DictationHotkeyName))
Write-Host ""

# 1) процессы
$sup = Get-DictationProcess "*examples.supervisor*"
$eng = Get-DictationProcess "*examples.voice_dictation*"
if ($sup) { Write-Host "Супервайзер (нянька): РАБОТАЕТ" -ForegroundColor Green }
else      { Write-Host "Супервайзер (нянька): НЕ ЗАПУЩЕН - нажмите кнопку «включить»" -ForegroundColor Red }
if ($eng) { Write-Host "Движок диктовки:      РАБОТАЕТ" -ForegroundColor Green }
else      { Write-Host "Движок диктовки:      НЕ ЗАПУЩЕН (после «включить» ему нужно ~20-30 сек)" -ForegroundColor Yellow }

# 2) пульс движка
$health = Join-Path $CFGDIR "health.json"
if (Test-Path $health) {
    try {
        $h = Get-Content $health -Raw | ConvertFrom-Json
        $age = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [double]$h.ts)
        if ($age -le 10) { Write-Host ("Пульс движка:         СВЕЖИЙ (" + $age + " сек назад)") -ForegroundColor Green }
        else             { Write-Host ("Пульс движка:         СТАРЫЙ (" + $age + " сек) - движок нездоров, супервайзер перезапустит") -ForegroundColor Yellow }
    } catch { Write-Host "Пульс движка:         не читается" -ForegroundColor Yellow }
} else {
    Write-Host "Пульс движка:         файла нет (движок ещё не запускался)" -ForegroundColor Yellow
}

# 3) Punto Switcher - известный конфликт со вставкой
$punto = Get-Process | Where-Object { $_.Name -like "*punto*" }
if ($punto) {
    Write-Host ""
    Write-Host "ВНИМАНИЕ: запущен Punto Switcher. Он может глотать вставку текста." -ForegroundColor Yellow
    Write-Host "Если распознавание слышно (сигналы), а текст не появляется - закройте"
    Write-Host "Punto на время диктовки (правой кнопкой по его значку у часов - Выход)."
}

# 4) микрофон: секундная запись и честный ответ
Write-Host ""
if (Test-Path $VPY) {
    Write-Host "Проверяю микрофон: скажите что-нибудь ВСЛУХ - записываю 2 секунды..."
    $micOut = & $VPY -c "import sounddevice as sd, numpy as np; r = sd.rec(int(16000*2), samplerate=16000, channels=1, dtype='float32'); sd.wait(); print('MIC_PEAK', float(abs(r).max()))" 2>&1
    $peak = 0.0
    foreach ($line in $micOut) {
        if ("$line" -like "MIC_PEAK*") { $peak = [double]("$line".Split(" ")[1]) }
    }
    if ($peak -gt 0.003) {
        Write-Host ("Микрофон слышит вас: ДА (уровень " + ("{0:N3}" -f $peak) + ")") -ForegroundColor Green
    } else {
        Write-Host "Микрофон слышит вас: НЕТ (тишина)" -ForegroundColor Red
        Write-Host "Откройте Параметры (сейчас открою) и включите ДВА переключателя:"
        Write-Host "«Доступ к микрофону» и «Разрешить классическим приложениям доступ к микрофону»."
        Write-Host "Если переключатели включены - проверьте, какой микрофон выбран:"
        Write-Host "Параметры - Система - Звук - Ввод."
        Start-Process "ms-settings:privacy-microphone"
    }
} else {
    Write-Host "Программа не установлена (нет окружения Python) - запустите «Установить для Windows.bat»." -ForegroundColor Red
}

# 5) хвосты логов
Write-Host ""
Write-Host "--- Последние строки журнала диктовки ---"
$dlog = Join-Path $CFGDIR "dictation.log"
if (Test-Path $dlog) { Get-Content $dlog -Tail 10 -Encoding UTF8 } else { Write-Host "(журнала ещё нет)" }
Write-Host ""
Write-Host "--- Последние строки журнала супервайзера ---"
$slog = Join-Path $CFGDIR "supervisor.log"
if (Test-Path $slog) { Get-Content $slog -Tail 8 -Encoding UTF8 } else { Write-Host "(журнала ещё нет)" }

Write-Host ""
Write-Host "Если не работает: сфотографируйте это окно и отправьте автору."
Read-Host "Enter чтобы закрыть"
exit 0
