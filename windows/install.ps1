# ============================================================
#  Диктовка ГигаАМ - установщик для Windows (бесплатный подарок)
#  Ставит всё сам. Модель берётся из пакета (офлайн) или из кэша.
#  Запускается кнопкой «Установить для Windows.bat» (та даёт Bypass).
# ============================================================
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$HERE   = Split-Path -Parent $PSScriptRoot      # корень распакованного пакета
$DEST   = Join-Path $env:USERPROFILE ".gigaam-dictation"
$CFGDIR = Join-Path $env:USERPROFILE ".config\whisper-skill"
$HFHUB  = Join-Path $env:USERPROFILE ".cache\huggingface\hub"
$VPY    = Join-Path $DEST ".venv\Scripts\python.exe"
$UVDIR  = Join-Path $env:USERPROFILE ".local\bin"
$UV     = Join-Path $UVDIR "uv.exe"
$UV_VER = "0.11.25"
# Контрольная сумма официального установщика uv для Windows (astral.sh/uv/0.11.25/install.ps1)
$UV_SHA = "e9d26d1b6c34553831c5334189c1e9e821e53bedc5ad9a37d88992b0355af965"

function Step([string]$t) { Write-Host ""; Write-Host (">>> " + $t) -ForegroundColor Green }
function Fail([string]$t) {
    Write-Host ""
    Write-Host ("ОШИБКА: " + $t) -ForegroundColor Red
    Write-Host "Покажите это окно автору (сфотографируйте или скопируйте текст)."
    Read-Host "Enter чтобы закрыть"
    exit 1
}

Clear-Host
Write-Host "============================================================"
Write-Host "   Установка «Диктовка ГигаАМ» для Windows"
Write-Host "   Идёт установка - это нормально. Ничего нажимать не надо,"
Write-Host "   я сам напишу, когда понадобитесь. НЕ закрывайте это окно."
Write-Host "============================================================"

# --- 0. проверки окружения ---
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    Fail "У вас Windows на ARM-процессоре (например, Surface). Эта версия пока поддерживает только обычные компьютеры Intel/AMD (64-разрядные). Напишите автору - добавлю поддержку ARM."
}
if (-not [Environment]::Is64BitOperatingSystem) {
    Fail "У вас 32-разрядная Windows. Нужна 64-разрядная Windows 10 или 11."
}
if (-not (Test-Path (Join-Path $HERE "src"))) {
    Fail "Рядом с установщиком нет папки src. Похоже, архив не распакован: закройте окно, нажмите правой кнопкой по скачанному ZIP - «Извлечь всё», и запустите установку из распакованной папки."
}

# --- 1. исходники + конфиг ---
Step "Шаг 1 из 6: копирую программу"
New-Item -ItemType Directory -Force -Path $DEST, $CFGDIR, $HFHUB | Out-Null
Copy-Item -Path (Join-Path $HERE "src\*") -Destination $DEST -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $DEST "windows") | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot "*.ps1") -Destination (Join-Path $DEST "windows") -Force
Get-ChildItem -Path $DEST -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
# Конфиг - ТОЛЬКО если его ещё нет: повторная установка = обновление,
# настройки человека (клавишу и пр.) не затираем.
$cfgFile = Join-Path $CFGDIR "voice_dictation.json"
if (-not (Test-Path $cfgFile)) {
    Copy-Item (Join-Path $HERE "config\voice_dictation.json") $cfgFile
    Write-Host "ок"
} else {
    Write-Host "ок (настройки уже есть - не трогаю)"
}
Set-Content -Path (Join-Path $DEST "VERSION") -Value ("windows-beta " + (Get-Date -Format "yyyy-MM-dd")) -Encoding Ascii

# --- 2. модель ---
Step "Шаг 2 из 6: голосовой движок (модель)"
$pkgModel = Join-Path $HERE "model\models--istupakov--gigaam-v3-onnx"
$hubModel = Join-Path $HFHUB "models--istupakov--gigaam-v3-onnx"
if (Test-Path $pkgModel) {
    Write-Host "беру модель из пакета (офлайн)..."
    Copy-Item -Path (Join-Path $HERE "model\*") -Destination $HFHUB -Recurse -Force
    Write-Host "ок (из пакета)"
} elseif (Test-Path $hubModel) {
    Write-Host "ок (модель уже есть в кэше)"
} else {
    Fail "Модели в пакете нет. Это неполная копия (например, git clone без архива). Возьмите ПОЛНЫЙ архив из раздела Releases - в нём вшита модель распознавания."
}

# --- 3. системный компонент Microsoft (нужен движку распознавания) ---
Step "Шаг 3 из 6: проверяю компонент Microsoft VC++"
if (Test-Path (Join-Path $env:SystemRoot "System32\msvcp140.dll")) {
    Write-Host "ок (уже установлен)"
} else {
    Write-Host "не найден - скачиваю официальный установщик Microsoft..."
    $vcexe = Join-Path $env:TEMP "vc_redist.x64.exe"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcexe -UseBasicParsing
    $sig = Get-AuthenticodeSignature $vcexe
    if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notlike "*Microsoft*") {
        Fail "Подпись установщика Microsoft не подтвердилась. Возможна подмена в сети - установка прервана для безопасности."
    }
    Write-Host "Сейчас Windows спросит разрешение (окно «Разрешить изменения?») - нажмите ДА."
    $p = Start-Process -FilePath $vcexe -ArgumentList "/install", "/passive", "/norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Fail ("Компонент Microsoft VC++ не установился (код " + $p.ExitCode + ").")
    }
    Remove-Item $vcexe -ErrorAction SilentlyContinue
    Write-Host "ок (установлен)"
}

# --- 4. uv + Python 3.11 ---
Step "Шаг 4 из 6: рабочее окружение Python (поставлю, если нет)"
# ВАЖНО (PowerShell 5.1): uv пишет прогресс в stderr; под $ErrorActionPreference=Stop
# редирект 2>&1 превратил бы это в ложный NativeCommandError и убил установку.
# Поэтому на native-вызовах ослабляем до Continue и судим по $LASTEXITCODE/проверкам.
$ErrorActionPreference = "Continue"
if (-not (Test-Path $UV)) {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { $UV = $cmd.Source }
}
if (-not (Test-Path $UV)) {
    Write-Host ("ставлю uv " + $UV_VER + " (с проверкой контрольной суммы установщика)...")
    $uvInstaller = Join-Path $env:TEMP "uv-install.ps1"
    Invoke-WebRequest -Uri ("https://astral.sh/uv/" + $UV_VER + "/install.ps1") -OutFile $uvInstaller -UseBasicParsing
    $gotSha = (Get-FileHash -Algorithm SHA256 $uvInstaller).Hash.ToLower()
    if ($gotSha -ne $UV_SHA) {
        Fail ("Контрольная сумма установщика uv НЕ совпала (" + $gotSha + "). Возможна подмена в сети - установка прервана.")
    }
    $env:XDG_BIN_HOME = $UVDIR
    $env:UV_INSTALL_DIR = $UVDIR
    & powershell -NoProfile -ExecutionPolicy Bypass -File $uvInstaller | Out-Null
    Remove-Item $uvInstaller -ErrorAction SilentlyContinue
    $UV = Join-Path $UVDIR "uv.exe"
    if (-not (Test-Path $UV)) { Fail "uv не установился." }
}
& $UV python install 3.11 2>&1 | Out-Null
& $UV venv --python 3.11 (Join-Path $DEST ".venv") 2>&1 | Out-Null
if (-not (Test-Path $VPY)) { Fail "Не удалось создать окружение Python 3.11." }
Write-Host "ок"

# --- 5. зависимости (зафиксированные версии + проверка хэшей каждого пакета) ---
Step "Шаг 5 из 6: ставлю компоненты распознавания (это пара минут)"
& $UV pip install --python $VPY --require-hashes -r (Join-Path $HERE "requirements-windows.lock") 2>&1 | ForEach-Object { $_ } | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) {
    Fail "Хэш пакета не совпал или нет интернета."
}
Write-Host "ок (версии и хэши проверены)"

# --- проверка движка: убедиться, что ГигаАМ загружается ---
Step "Проверяю, что распознаёт именно ГигаАМ..."
$env:HF_HUB_OFFLINE = "1"
$engineCheck = & $VPY -c "import onnx_asr; m = onnx_asr.load_model('gigaam-v3-e2e-rnnt', providers=['CPUExecutionProvider']); print('GIGAAM_OK')" 2>&1
if ("$engineCheck" -notlike "*GIGAAM_OK*") {
    Fail ("Движок не загрузился: " + $engineCheck)
}
Write-Host "ок - движок ГигаАМ загружается"
$ErrorActionPreference = "Stop"

# --- 6. кнопки на Рабочем столе ---
Step "Шаг 6 из 6: кнопки на Рабочем столе"
$desk = [Environment]::GetFolderPath("Desktop")
$psRun = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%USERPROFILE%\.gigaam-dictation\windows\{0}`"`r`nif errorlevel 1 pause`r`n"
Set-Content -Path (Join-Path $desk "Диктовка ГигаАМ - включить.bat")  -Value ($psRun -f "start.ps1")     -Encoding Ascii
Set-Content -Path (Join-Path $desk "Диктовка ГигаАМ - выключить.bat") -Value ($psRun -f "stop.ps1")      -Encoding Ascii
Set-Content -Path (Join-Path $desk "Диктовка ГигаАМ - проверить.bat") -Value ($psRun -f "check.ps1")     -Encoding Ascii
Set-Content -Path (Join-Path $desk "Диктовка ГигаАМ - удалить.bat")   -Value ($psRun -f "uninstall.ps1") -Encoding Ascii
Write-Host "ок"

# --- микрофон ---
Step "Последнее: доступ к микрофону (один раз)"
Write-Host "Сейчас откроются Параметры. Включите ДВА переключателя:"
Write-Host "  1) «Доступ к микрофону» - Вкл."
Write-Host "  2) «Разрешить классическим приложениям доступ к микрофону» - Вкл."
Write-Host "Нашей программы в списке НЕ будет - это нормально, ей хватает этих двух."
Start-Process "ms-settings:privacy-microphone"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ГОТОВО. Что дальше:"
Write-Host "   1) В открывшихся Параметрах включите оба переключателя микрофона."
Write-Host "   2) Дважды щёлкните на Рабочем столе «Диктовка ГигаАМ - включить»."
Write-Host "   3) Поставьте курсор в любое поле, зажмите ПРАВЫЙ Ctrl, говорите,"
Write-Host "      отпустите - текст появится."
Write-Host ""
Write-Host "  Клавиша диктовки - ПРАВЫЙ Ctrl (нижний правый угол клавиатуры,"
Write-Host "  справа от пробела и правого Alt). Левый Ctrl не сработает."
Write-Host "     [Ctrl] [Win] [Alt] [   ПРОБЕЛ   ] [Alt] [Ctrl <- ЭТОТ]"
Write-Host ""
Write-Host "  Не работает? Кнопка «Диктовка ГигаАМ - проверить»."
Write-Host "============================================================" -ForegroundColor Green
Read-Host "Нажмите Enter чтобы закрыть это окно"
exit 0
