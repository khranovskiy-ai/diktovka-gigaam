# Кнопка «Диктовка ГигаАМ - включить» (Windows).
# Гасит старые процессы, запускает СУПЕРВАЙЗЕР без окна (тот сам поднимает
# движок и перезапускает его при любых зависаниях - кнопку жать не нужно).
$ErrorActionPreference = "SilentlyContinue"
. "$PSScriptRoot\common.ps1"

$PW = Join-Path $DEST ".venv\Scripts\pythonw.exe"
if (-not (Test-Path $PW)) { $PW = Join-Path $DEST ".venv\Scripts\python.exe" }

Write-Host "Включаю диктовку..."
Stop-DictationProcesses
Start-Process -FilePath $PW -ArgumentList "-m", "examples.supervisor" -WorkingDirectory $DEST -WindowStyle Hidden
Start-Sleep -Seconds 3

if (Get-DictationProcess "*examples.supervisor*") {
    $hk = Get-DictationHotkeyName
    Write-Host ""
    Write-Host "Диктовка включается. Движку нужно ~20-30 секунд, чтобы загрузиться." -ForegroundColor Green
    Write-Host ""
    Write-Host ("Дальше: поставьте курсор в любое поле, зажмите " + $hk + ",")
    Write-Host "скажите фразу по-русски, отпустите - текст появится сам."
    Write-Host "При нажатии услышите короткий сигнал, при отпускании - второй."
    Write-Host ""
    Write-Host "Диктовка под присмотром: если что-то зависнет, она сама перезапустится."
    Write-Host "Это окно сейчас закроется."
    Start-Sleep -Seconds 8
} else {
    Write-Host ""
    Write-Host "Не удалось запустить диктовку." -ForegroundColor Red
    Write-Host "Нажмите кнопку «Диктовка ГигаАМ - проверить» и напишите автору."
    Read-Host "Enter чтобы закрыть"
}
exit 0
