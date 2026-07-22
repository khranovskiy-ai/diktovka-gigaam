# Кнопка «Диктовка ГигаАМ - выключить» (Windows).
$ErrorActionPreference = "SilentlyContinue"
. "$PSScriptRoot\common.ps1"

Write-Host "Выключаю диктовку..."
Stop-DictationProcesses
Write-Host "Диктовка выключена. Включить снова - кнопка «Диктовка ГигаАМ - включить»." -ForegroundColor Green
Start-Sleep -Seconds 3
exit 0
